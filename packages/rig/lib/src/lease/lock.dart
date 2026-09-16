import 'dart:io';

import '../errors.dart';

/// A lock older than this is assumed to belong to a crashed holder.
///
/// The lock is only held across a create and a start — a few seconds — so
/// this is generous by two orders of magnitude.
const Duration defaultLockStaleAfter = Duration(seconds: 120);

const Duration _defaultTimeout = Duration(seconds: 60);
const Duration _defaultRetryInterval = Duration(milliseconds: 25);

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

    if (_isStale(link, now(), staleAfter)) {
      _release(link);
      continue;
    }

    if (!now().isBefore(deadline)) {
      throw LockTimeout(lockPath: lockPath, waited: timeout);
    }
    await sleep(retryInterval);
  }
}

/// True when this call created the link. The target is a marker, not a real
/// path: a dangling symlink is fine and its target is readable.
bool _tryCreate(Link link, DateTime at) {
  try {
    link.createSync('held-at:${at.toUtc().toIso8601String()}|pid:$pid');
    return true;
  } on FileSystemException {
    return false;
  }
}

bool _isStale(Link link, DateTime at, Duration staleAfter) {
  final held = _heldAt(link);
  // An unreadable marker is treated as stale: a lock nobody can reason about
  // must not block every future run forever.
  if (held == null) return true;
  return at.toUtc().difference(held) > staleAfter;
}

DateTime? _heldAt(Link link) {
  try {
    final target = link.targetSync();
    final match = RegExp(r'held-at:([^|]+)').firstMatch(target);
    if (match == null) return null;
    return DateTime.tryParse(match.group(1)!)?.toUtc();
  } on FileSystemException {
    return null;
  }
}

void _release(Link link) {
  try {
    link.deleteSync();
  } on FileSystemException {
    // Already gone, or taken over. Either way there is nothing to undo.
  }
}

Future<void> _delay(Duration d) => Future<void>.delayed(d);
