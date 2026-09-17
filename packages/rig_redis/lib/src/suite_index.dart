import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rig/module.dart';
import 'package:rig/rig.dart';

/// How long a suite's marker is trusted before its database index is
/// presumed abandoned and free for another suite to claim.
///
/// A day, against test runs measured in minutes — the same value and the
/// same reasoning `rig_postgres` uses for its own marker: a marker younger
/// than this protects its index unconditionally, because no age or
/// connection check can tell a suite sitting between two connections from
/// one that crashed. Unlike `rig_postgres`, there is no separate "how stale
/// is the resource itself" threshold here: a suite database's name carries
/// its creation minute, but a Redis index is just a number with no
/// timestamp of its own, so the marker's own age is the only signal there
/// is.
const Duration defaultMarkerStaleAfter = Duration(hours: 24);

/// Where the marker recording that a suite has claimed [index] inside
/// [containerId] lives.
///
/// Deliberately not under [StateDir.suitesDir]. That directory's contract —
/// the one `rig prune` sweeps by — is "a subdirectory whose container is
/// gone can be removed", which is right for `rig_postgres`: every suite
/// database there has a name unique to that suite, so nothing is ever
/// waiting to reuse one. A Redis index is the opposite — it is one of a
/// small fixed set of numbers the *next* suite on this same container is
/// meant to reuse, reclaimed the moment a new suite actually needs it rather
/// than on `rig prune`'s schedule. Filing it next to `rig_postgres`'s
/// markers, under a directory whose name promises something that is not
/// true here, would be the wrong kind of reuse.
File suiteIndexMarker({
  required StateDir stateDir,
  required String containerId,
  required int index,
}) => File(p.join(stateDir.root.path, 'redis', containerId, '$index'));

/// Every database index this container was started with is already claimed
/// by a marker that has not gone stale.
final class RedisDatabasesExhausted extends RigException {
  const RedisDatabasesExhausted({
    required this.used,
    required this.capacity,
    required this.containerId,
  });

  /// How many indices are currently claimed.
  final int used;

  /// How many indices this container has to give out — `databases - 1`,
  /// since index 0 is reserved for `RedisIsolation.none`.
  final int capacity;

  final String containerId;

  @override
  String get message =>
      'Every database index container $containerId has to give a suite of '
      'its own is claimed: $used of $capacity in use.\n\n'
      'This container may be shared with other projects on this machine, '
      'not just this one — $capacity is not "$capacity per project".\n\n'
      'Either raise `databases:` on useRedis() so there is more to hand '
      'out, or ask for `lifetime: Lifetime.dedicated` so this suite gets a '
      'container nothing else is drawing from.';
}

/// The index this suite claimed could not be flushed before being handed to
/// it.
final class RedisIndexNotFlushed extends RigException {
  const RedisIndexNotFlushed({
    required this.index,
    required this.containerId,
    required this.detail,
  });

  final int index;
  final String containerId;
  final String detail;

  @override
  String get message =>
      'Could not FLUSHDB index $index in container $containerId before '
      "handing it to this suite, so it might still carry another suite's "
      'keys.\n$detail\n\n'
      'Check that the container is healthy (docker logs) and that '
      'redis-cli is reachable inside it.';
}

/// Claims the smallest database index nobody else is holding, flushes it,
/// and marks it as this suite's. Never returns `0`, which `RedisIsolation.
/// none` reserves for itself.
///
/// Must run with nothing else claiming an index for the same [containerId]
/// at the same time (`useRedis` does this with `withExclusiveLock`), because
/// Redis has no notion of "reserved but not yet written to" this could ask
/// about instead: `INFO keyspace` only lists a database once it holds a key,
/// so the marker on the filesystem is the only record of a claim that
/// has not written anything yet.
///
/// The chosen index is flushed before it is handed back, whether or not it
/// looked freshly claimed: one with no marker at all may still carry keys
/// left by something outside this module's tracking, and one reclaimed from
/// a stale marker definitely carries a crashed suite's keys. Skipping the
/// flush for an index that merely lacked a marker would leave that path
/// unguarded.
Future<int> claimSuiteIndex({
  required DockerEngine engine,
  required String containerId,
  required int databases,
  required String? password,
  required DateTime now,
  required StateDir stateDir,
  Duration markerStaleAfter = defaultMarkerStaleAfter,
}) async {
  final capacity = databases > 1 ? databases - 1 : 0;

  int? chosen;
  for (var index = 1; index < databases; index++) {
    final marker = suiteIndexMarker(
      stateDir: stateDir,
      containerId: containerId,
      index: index,
    );
    if (marker.existsSync()) {
      final age = now.toUtc().difference(marker.lastModifiedSync().toUtc());
      // A marker within markerStaleAfter still protects its index, however
      // long it has been since anyone connected — a suite between
      // connections is exactly what the marker exists to protect. Only a
      // marker older than this is presumed to belong to a suite that
      // crashed before teardown ever ran.
      if (age <= markerStaleAfter) continue;
    }
    chosen = index;
    break;
  }

  if (chosen == null) {
    throw RedisDatabasesExhausted(
      used: capacity,
      capacity: capacity,
      containerId: containerId,
    );
  }

  final flush = await _redisCli(engine, containerId, password, [
    '-n',
    '$chosen',
    'FLUSHDB',
  ]);
  // redis-cli can exit 0 on a reply that is not the one asked for (e.g.
  // NOAUTH), the same reason this module's injected healthcheck greps
  // instead of trusting the exit code — so a successful FLUSHDB is
  // confirmed by its reply text, not just the exit code.
  if (flush.exitCode != 0 || flush.output.trim() != 'OK') {
    throw RedisIndexNotFlushed(
      index: chosen,
      containerId: containerId,
      detail: flush.output,
    );
  }

  final marker = suiteIndexMarker(
    stateDir: stateDir,
    containerId: containerId,
    index: chosen,
  );
  marker.parent.createSync(recursive: true);
  marker.writeAsStringSync('');

  return chosen;
}

/// Flushes [index] and clears its marker, so another suite can claim it
/// right away instead of waiting for [defaultMarkerStaleAfter] to pass.
///
/// Mirrors `rig_postgres`'s `dropSuiteDatabase` in tolerating a container
/// that is already gone — a `rig prune` or a Docker restart between the
/// lease resolving and teardown reaching this — by leaving the marker in
/// place rather than throwing: nothing here can tell whether the index went
/// with the container, and a suite failing in teardown over that would turn
/// an otherwise-passing run red.
Future<void> releaseSuiteIndex({
  required DockerEngine engine,
  required String containerId,
  required int index,
  required String? password,
  required StateDir stateDir,
}) async {
  try {
    await _redisCli(engine, containerId, password, ['-n', '$index', 'FLUSHDB']);
  } on EngineError catch (e) {
    // ignore: avoid_print
    print(
      'rig_redis: could not flush index $index in container $containerId '
      'because Docker could not run the command: $e',
    );
    return;
  }

  final marker = suiteIndexMarker(
    stateDir: stateDir,
    containerId: containerId,
    index: index,
  );
  try {
    if (marker.existsSync()) marker.deleteSync();
  } on FileSystemException {
    // Nothing to undo if it cannot be removed.
  }
}

List<String> _redisCliCommand(String? password, List<String> args) => [
  'redis-cli',
  if (password != null) ...['-a', password, '--no-auth-warning'],
  ...args,
];

Future<ExecResult> _redisCli(
  DockerEngine engine,
  String containerId,
  String? password,
  List<String> args,
) => engine.exec(containerId, _redisCliCommand(password, args));
