import 'dart:io';

import 'package:rig/module.dart';
import 'package:rig/rig.dart';

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
    kind: 'postgres',
    containerId: containerId,
    resource: database,
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
    kind: 'postgres',
    containerId: containerId,
    resource: database,
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

  for (final name in listing.output.split('\n')) {
    final candidate = name.trim();
    if (candidate.isEmpty) continue;

    final marker = suiteMarkerFile(
      stateDir: stateDir,
      kind: 'postgres',
      containerId: containerId,
      resource: candidate,
    );
    if (!isReclaimableSuiteDatabase(
      database: candidate,
      now: now,
      marker: marker,
      staleAfter: staleAfter,
      markerStaleAfter: markerStaleAfter,
    )) {
      continue;
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
