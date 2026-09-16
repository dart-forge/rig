import 'dart:io';
import 'dart:math';

import '../errors.dart';

/// A lock older than this is assumed to belong to a crashed holder.
///
/// The lock is only held across a create and a start — a few seconds — so
/// this is generous by two orders of magnitude.
const Duration defaultLockStaleAfter = Duration(seconds: 120);

const Duration _defaultTimeout = Duration(seconds: 60);
const Duration _defaultRetryInterval = Duration(milliseconds: 25);

final Random _tokens = Random();

/// Run [body] with nothing else holding [lockPath].
///
/// Implemented as an atomic symlink creation rather than with
/// `RandomAccessFile.lock`. POSIX record locks are owned by the *process*, so
/// a second request from the same process succeeds — which would silently
/// break whenever `dart test` runs suites as isolates in one process.
/// `symlink(2)` fails when the name exists, whoever asks, so the filesystem
/// itself provides the exclusion.
Future<T> withExclusiveLock<T>(
  String lockPath,
  Future<T> Function() body, {
  Duration staleAfter = defaultLockStaleAfter,
  Duration timeout = _defaultTimeout,
  Duration retryInterval = _defaultRetryInterval,
  DateTime Function() now = DateTime.now,
  Future<void> Function(Duration) sleep = _delay,
}) async {
  final link = Link(lockPath);
  link.parent.createSync(recursive: true);

  final deadline = now().add(timeout);

  while (true) {
    if (_tryCreate(link, now())) {
      try {
        return await body();
      } finally {
        _release(link);
      }
    }

    // Checked on every turn of the loop, not only on the waiting branch.
    // The stale branch retries immediately so a crashed holder is recovered
    // from fast — which means that without this it would spin without end
    // whenever the stale lock cannot actually be deleted. Hanging is the one
    // failure this library exists to remove, so no path may be unbounded.
    if (!now().isBefore(deadline)) {
      throw LockTimeout(lockPath: lockPath, waited: timeout);
    }

    final held = _readTarget(link);
    if (held == null || _isStale(held, now(), staleAfter)) {
      breakStaleLockIfUnchanged(link, held);
    } else {
      await sleep(retryInterval);
    }
  }
}

/// True when this call created the link. The target is a marker, not a real
/// path: a dangling symlink is fine and its target is readable.
bool _tryCreate(Link link, DateTime at) {
  try {
    link.createSync(_marker(at));
    return true;
  } on FileSystemException {
    return false;
  }
}

/// Identifies one holder. The random token matters: two isolates in one
/// process share a pid, and without it two holders could write the same
/// marker — which would defeat the comparison in [breakStaleLockIfUnchanged].
String _marker(DateTime at) =>
    'held-at:${at.toUtc().toIso8601String()}'
    '|pid:$pid'
    '|token:${_tokens.nextInt(1 << 32).toRadixString(16)}';

/// Removes the lock, but only while it still carries exactly [observed].
///
/// Not private so that rig's own tests can drive the interleaving directly.
/// Reproducing it through two real isolates turned out not to be reliable —
/// isolate startup jitter is wider than the window — so the decision is
/// tested as a function instead of raced.
///
/// The comparison is the point. Deleting by path alone lets a caller that
/// judged a lock stale delete the *fresh* lock a faster caller created in the
/// meantime, putting two callers inside the critical section at once. A
/// marker carries a pid and a random token, so a fresh lock never looks like
/// the expired one. Two callers breaking the *same* stale lock is harmless:
/// the second delete finds nothing and the loser simply waits for the winner.
///
/// No syscall offers compare-and-delete, so a window one syscall wide
/// remains. Its worst outcome is two callers each creating a container for
/// the same spec, which leaves one spare for `rig prune` rather than giving
/// either caller the wrong container.
void breakStaleLockIfUnchanged(Link link, String? observed) {
  if (_readTarget(link) != observed) return;
  _release(link);
}

/// An unreadable marker counts as stale: a lock nobody can reason about must
/// not block every future run forever.
bool _isStale(String target, DateTime at, Duration staleAfter) {
  final held = _heldAt(target);
  if (held == null) return true;
  return at.toUtc().difference(held) > staleAfter;
}

String? _readTarget(Link link) {
  try {
    return link.targetSync();
  } on FileSystemException {
    return null;
  }
}

DateTime? _heldAt(String target) {
  final match = RegExp(r'held-at:([^|]+)').firstMatch(target);
  if (match == null) return null;
  return DateTime.tryParse(match.group(1)!)?.toUtc();
}

void _release(Link link) {
  try {
    link.deleteSync();
  } on FileSystemException {
    // Already gone, or taken over. Either way there is nothing to undo.
  }
}

Future<void> _delay(Duration d) => Future<void>.delayed(d);
