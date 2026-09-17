import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:rig/module.dart';
import 'package:rig/rig.dart';

/// How long a suite database has to sit unused before it is treated as
/// abandoned.
///
/// Well above a minute on purpose: a name carries the minute it was created
/// in, floored, so anything near that resolution cannot distinguish a
/// database abandoned an hour ago from one created moments before a minute
/// boundary.
const Duration defaultStaleAfter = Duration(hours: 1);

/// How long a suite's marker is trusted before the suite is presumed gone.
///
/// A day, against test runs measured in minutes. A marker younger than this
/// protects its database unconditionally — no age or connection check can
/// tell a suite sitting between two connections from an abandoned one, which
/// is why the marker exists. Older than this and the suite is not coming
/// back, and without that half the sweep would reclaim nothing at all: a
/// database whose teardown ran was already dropped by that teardown, so every
/// database the sweep meets still carries its marker.
const Duration defaultMarkerStaleAfter = Duration(hours: 24);

final Random _tokens = Random();

/// The minute [at] falls in, as it appears inside a database name.
String minuteStampOf(DateTime at) =>
    '${at.toUtc().millisecondsSinceEpoch ~/ 60000}';

/// A fresh token for a suite database name.
String newSuiteToken() =>
    _tokens.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');

/// A database name for one suite.
///
/// The project makes a stray database traceable to the package that left it,
/// and the minute stamp is how an abandoned one is recognised later: Postgres
/// does not record when a database was created, so the name has to. Without it
/// there would be no way to tell a database a crashed suite left behind from
/// one another suite created a moment ago.
String suiteDatabaseName({
  required String project,
  required DateTime now,
  required String token,
}) {
  final slug = _slugOf(project);
  final stamp = minuteStampOf(now);
  // Identifiers cap at 63 characters, and the stamp and token have to survive
  // whatever the project is called.
  final room = 63 - 'test__${stamp}_$token'.length;
  final trimmed = slug.length > room ? slug.substring(0, room) : slug;
  return 'test_${trimmed}_${stamp}_$token';
}

/// A project name reduced to something legal inside an identifier.
///
/// Never empty, and that is the point rather than tidiness. The name's shape —
/// four underscore-separated parts — is how the sweep recognises a database it
/// created. A project that slugged away to nothing would produce a three-part
/// name that [createdAtOf] rejects, so the sweep would skip it forever, in a
/// container that is deliberately never removed. `currentProjectName` returns
/// an empty string when it finds no pubspec, so this is reachable rather than
/// hypothetical.
String _slugOf(String project) {
  final slug = project
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  return slug.isEmpty ? 'unnamed' : slug;
}

/// Where the marker recording that [database] inside [containerId] belongs to
/// a suite that is still running is kept.
///
/// A file rather than an in-memory flag: `dart test` gives every suite file
/// its own isolate, and isolates share no memory, so the filesystem is the
/// one channel every isolate in a run can see. Written by
/// [createSuiteDatabase] and removed by [dropSuiteDatabase]; not private so a
/// test can plant or inspect one directly.
File suiteMarkerFile({
  required StateDir stateDir,
  required String containerId,
  required String database,
}) => File(p.join(stateDir.root.path, 'suites', containerId, database));

/// The suite's own database could not be created.
final class SuiteDatabaseNotCreated extends RigException {
  const SuiteDatabaseNotCreated({required this.database, required this.detail});

  final String database;
  final String detail;

  @override
  String get message =>
      'Could not create $database for this suite, so the suite would have '
      'run against the container\'s shared database instead, seeing tables '
      'other suites created.\n$detail\n\n'
      'Check that the container is healthy (docker logs) and that the '
      'admin user has permission to create databases.';
}

/// Creates [database] for one suite inside a container others are sharing,
/// and marks it as belonging to a running suite.
Future<void> createSuiteDatabase({
  required DockerEngine engine,
  required String containerId,
  required String user,
  required String adminDatabase,
  required String database,
  required StateDir stateDir,
}) async {
  // template0 rather than template1: template1 is where a person's own
  // additions live, and an open connection to it makes CREATE DATABASE fail.
  final result = await _psql(
    engine,
    containerId,
    user,
    adminDatabase,
    'CREATE DATABASE $database TEMPLATE template0',
  );
  if (result.exitCode != 0) {
    throw SuiteDatabaseNotCreated(database: database, detail: result.output);
  }

  final marker = suiteMarkerFile(
    stateDir: stateDir,
    containerId: containerId,
    database: database,
  );
  marker.parent.createSync(recursive: true);
  marker.writeAsStringSync('');
}

/// Drops [database] and clears its marker. Silent when the database is
/// already gone.
///
/// [force] defaults to true: a suite dropping its own database in teardown
/// wants a leaked connection of its own to not block that. The sweep asks for
/// `force: false` instead — forcing there would remove the very protection
/// the "nobody connected" check exists to give a live suite between
/// connections.
Future<void> dropSuiteDatabase({
  required DockerEngine engine,
  required String containerId,
  required String user,
  required String adminDatabase,
  required String database,
  required StateDir stateDir,
  bool force = true,
}) async {
  // No throw on a failed DROP: teardown also runs after a failure, and a
  // database that is already gone is the state teardown was asking for. A
  // failure inside Docker itself — the container vanished, the daemon went
  // away — is a different thing and is caught below instead of turning a
  // passing suite red in tearDownAll.
  try {
    await _dropDatabaseSql(
      engine,
      containerId,
      user,
      adminDatabase,
      database,
      force,
    );
  } on EngineError catch (e) {
    // ignore: avoid_print
    print(
      'rig_postgres: could not drop suite database $database in container '
      '$containerId because Docker could not run the command: $e',
    );
    // The container is gone, so nothing here can tell whether its database
    // went with it. Leaving the marker in place is deliberate: rig prune
    // reclaims a marker directory once its container is no longer known to
    // the daemon.
    return;
  }

  final marker = suiteMarkerFile(
    stateDir: stateDir,
    containerId: containerId,
    database: database,
  );
  try {
    if (marker.existsSync()) marker.deleteSync();
  } on FileSystemException {
    // Nothing to undo if it cannot be removed.
  }
}

/// Drops suite databases nobody is connected to, that are old enough to be
/// considered abandoned, and whose marker is either absent or itself too old
/// to trust — and returns the ones it dropped.
///
/// Shared containers are deliberately long-lived, and each suite database is a
/// clone of template0 sitting in a tmpfs — so a run that dies before its
/// teardown costs memory until something clears it.
///
/// A broken sweep is not worth failing a test run over: a failure inside
/// Docker itself (as opposed to a failed SQL statement, which is a normal
/// outcome here) is caught, printed, and answered with whatever this had
/// already dropped. What actually keeps a suite's own database isolated is
/// [createSuiteDatabase], whether or not this ever runs. Catching only the
/// engine's own failure type, not [Object], means a bug in this file still
/// reaches the developer instead of being swallowed the same way.
Future<List<String>> dropStaleSuiteDatabases({
  required DockerEngine engine,
  required String containerId,
  required String user,
  required String adminDatabase,
  required DateTime now,
  required StateDir stateDir,
  Duration staleAfter = defaultStaleAfter,
  Duration markerStaleAfter = defaultMarkerStaleAfter,
}) async {
  final dropped = <String>[];

  // Age alone is not evidence: a suite holding a lease may simply be between
  // connections. Neither is "nobody connected" alone, for the same reason.
  // What actually distinguishes a live suite is the marker
  // createSuiteDatabase writes and dropSuiteDatabase removes — the
  // filesystem is the one channel every isolate in a `dart test` run can
  // see, unlike anything held in memory.
  ExecResult listing;
  try {
    listing = await _psql(
      engine,
      containerId,
      user,
      adminDatabase,
      "SELECT d.datname FROM pg_database d "
      "WHERE d.datname LIKE 'test\\_%' "
      "AND NOT EXISTS (SELECT 1 FROM pg_stat_activity a "
      "WHERE a.datname = d.datname)",
    );
  } on EngineError catch (e) {
    _printCouldNotSweep(containerId, e);
    return dropped;
  }
  if (listing.exitCode != 0) {
    // A shared container's data directory is a tmpfs. A sweep that silently
    // never runs lets suite databases accumulate in RAM until the container
    // cannot write, which surfaces weeks later as "No space left on device"
    // in some unrelated suite. Printing here is the only trace of that until
    // then, and nothing about it is worth failing this test run over.
    // ignore: avoid_print
    print(
      'rig_postgres: could not list suite databases in container '
      '$containerId to sweep them: ${listing.output}',
    );
    return dropped;
  }

  final cutoff = now.toUtc().subtract(staleAfter);

  for (final name in listing.output.split('\n')) {
    final candidate = name.trim();
    if (candidate.isEmpty) continue;

    final createdAt = createdAtOf(candidate);
    if (createdAt == null) continue;

    // The stamp is the minute the database was created in, floored, so the
    // database can be up to a minute younger than it claims. Judge it by the
    // latest moment it could have been created, never the earliest: being
    // wrong in the other direction would drop a database whose own suite has
    // not connected to it yet.
    final createdNoLaterThan = createdAt.add(const Duration(minutes: 1));
    if (!createdNoLaterThan.isBefore(cutoff)) continue;

    // A fresh marker means some suite still claims this database, however
    // long it has been since anyone connected to it — a suite between
    // connections is exactly what the marker exists to protect. But a
    // marker only survives as long as its suite does: teardown is what
    // removes it, so a database whose teardown ran was already dropped by
    // that same teardown. Every database that reaches this point either
    // never had a marker, or still carries one from a suite that never got
    // to teardown — and only the marker's own age, on a much longer
    // threshold than staleAfter (a run lasts minutes, abandonment is a
    // matter of days), can tell those two apart from a suite that is
    // genuinely still running.
    final marker = suiteMarkerFile(
      stateDir: stateDir,
      containerId: containerId,
      database: candidate,
    );
    if (marker.existsSync()) {
      final markerAge = now.toUtc().difference(
        marker.lastModifiedSync().toUtc(),
      );
      if (markerAge <= markerStaleAfter) continue;
    }

    // force: false, same as dropSuiteDatabase's own sweep-driven call below
    // would use — forcing here would remove the very protection the "nobody
    // connected" check exists to give a live suite between connections. That
    // is exactly why this DROP can fail as a normal outcome (a backend
    // connected between the listing above and this statement), which is why
    // the result is inspected directly here rather than through
    // dropSuiteDatabase, whose whole contract for teardown is to not do
    // that.
    ExecResult dropResult;
    try {
      dropResult = await _dropDatabaseSql(
        engine,
        containerId,
        user,
        adminDatabase,
        candidate,
        false,
      );
    } on EngineError catch (e) {
      _printCouldNotSweep(containerId, e);
      return dropped;
    }

    if (dropResult.exitCode != 0) {
      // Nothing was actually dropped, so the database is still there and its
      // marker (if any) must stay — reporting either otherwise would be
      // printing the opposite of what happened.
      // ignore: avoid_print
      print(
        'rig_postgres: skipped stale suite database $candidate in '
        'container $containerId because the drop did not succeed: '
        '${dropResult.output}',
      );
      continue;
    }

    try {
      if (marker.existsSync()) marker.deleteSync();
    } on FileSystemException {
      // Nothing to undo if it cannot be removed.
    }

    dropped.add(candidate);
    // ignore: avoid_print
    print(
      'rig_postgres: dropped stale suite database $candidate in container '
      '$containerId',
    );
  }
  return dropped;
}

void _printCouldNotSweep(String containerId, EngineError e) {
  // ignore: avoid_print
  print(
    'rig_postgres: could not sweep stale suite databases in container '
    '$containerId because Docker could not run the command: $e',
  );
}

/// The minute stamp out of a name this module produced, or null when the name
/// did not come from here.
///
/// Not private so a test can check the round trip. A generator that can emit a
/// name its own parser rejects leaves databases nobody ever cleans up, and
/// that pair is worth pinning directly rather than through the sweep.
DateTime? createdAtOf(String database) {
  final match = RegExp(r'^test_.*_(\d+)_[0-9a-f]{8}$').firstMatch(database);
  if (match == null) return null;
  final minutes = int.tryParse(match.group(1)!);
  if (minutes == null) return null;
  return DateTime.fromMillisecondsSinceEpoch(minutes * 60000, isUtc: true);
}

Future<ExecResult> _psql(
  DockerEngine engine,
  String containerId,
  String user,
  String database,
  String sql,
) =>
    engine.exec(containerId, ['psql', '-U', user, '-d', database, '-tAc', sql]);

/// Runs the DROP itself and hands back what psql said, without deciding what
/// that means — [dropSuiteDatabase] ignores it (teardown's job), and
/// [dropStaleSuiteDatabases] inspects it directly (the sweep's job), and
/// each needs to keep doing only that.
Future<ExecResult> _dropDatabaseSql(
  DockerEngine engine,
  String containerId,
  String user,
  String adminDatabase,
  String database,
  bool force,
) => _psql(
  engine,
  containerId,
  user,
  adminDatabase,
  'DROP DATABASE IF EXISTS $database${force ? ' WITH (FORCE)' : ''}',
);
