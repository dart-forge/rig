import 'dart:io';

import 'package:rig/module.dart';
import 'package:rig/rig.dart';

import 'mysql_exec.dart';

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
      'Check that the container is healthy (docker logs) and that the root '
      'password reached it.';
}

/// The database was created but could not be marked as in use.
final class SuiteMarkerNotWritten extends RigException {
  const SuiteMarkerNotWritten({required this.database, required this.detail});

  final String database;
  final String detail;

  @override
  String get message =>
      'Created $database but could not record that this suite is using it, '
      'so the sweep would have reclaimed it from underneath this run. The '
      'database has been dropped again rather than left unprotected.\n'
      '$detail';
}

/// Creates [database] for one suite inside a container others are sharing,
/// grants [user] on it, and marks it as belonging to a running suite.
///
/// There is no template to choose: MySQL has no equivalent of Postgres's
/// template databases, so a fresh database is simply empty. The grant is what
/// makes it usable at all — `MYSQL_USER` holds rights on `MYSQL_DATABASE`
/// and nothing else.
///
/// The marker is written last, and a failure to write it is fatal. MySQL's
/// `DROP DATABASE` succeeds even while something is connected, so unlike
/// Postgres there is no second line of defence: the marker is the only thing
/// standing between a live suite and the sweep. A database without one would
/// be reclaimed under a running suite, which is worth failing over — and the
/// database goes with it rather than leaking.
Future<void> createSuiteDatabase({
  required DockerEngine engine,
  required String containerId,
  required String rootPassword,
  required String user,
  required String database,
  required StateDir stateDir,
}) async {
  final quoted = mysqlIdentifier(database);
  // Both statements in one call. If the grant fails after the create
  // succeeded, the database is left behind for the sweep to reclaim, which
  // is the same outcome as any other failure here.
  final result = await runMysql(
    engine,
    containerId,
    rootPassword: rootPassword,
    sql:
        'CREATE DATABASE $quoted; '
        'GRANT ALL PRIVILEGES ON $quoted.* '
        'TO ${mysqlStringLiteral(user)}@${mysqlStringLiteral('%')}',
  );
  if (result.exitCode != 0) {
    throw SuiteDatabaseNotCreated(database: database, detail: result.output);
  }

  final marker = suiteMarkerFile(
    stateDir: stateDir,
    kind: 'mysql',
    containerId: containerId,
    resource: database,
  );
  try {
    marker.parent.createSync(recursive: true);
    marker.writeAsStringSync('');
  } on FileSystemException catch (e) {
    await _dropDatabase(engine, containerId, rootPassword, database);
    throw SuiteMarkerNotWritten(database: database, detail: '$e');
  }
}

/// Drops [database] and clears its marker. Silent when the database is
/// already gone.
///
/// No `force` to ask for: MySQL drops a database whether or not anything is
/// connected to it, so the clause Postgres needs has no counterpart here.
Future<void> dropSuiteDatabase({
  required DockerEngine engine,
  required String containerId,
  required String rootPassword,
  required String database,
  required StateDir stateDir,
}) async {
  // No throw on a failed DROP: teardown also runs after a failure, and a
  // database that is already gone is the state teardown was asking for. A
  // failure inside Docker itself — the container vanished, the daemon went
  // away — is a different thing and is caught below instead of turning a
  // passing suite red in tearDownAll.
  try {
    await _dropDatabase(engine, containerId, rootPassword, database);
  } on EngineError catch (e) {
    // ignore: avoid_print
    print(
      'rig_mysql: could not drop suite database $database in container '
      '$containerId because Docker could not run the command: $e',
    );
    // The container is gone, so nothing here can tell whether its database
    // went with it. Leaving the marker in place is deliberate: rig prune
    // reclaims a marker directory once its container is no longer known to
    // the daemon.
    return;
  }

  _clearMarker(stateDir, containerId, database);
}

/// Drops suite databases that are old enough to be considered abandoned and
/// that no running suite still claims — and returns the ones it dropped.
///
/// Shared containers are deliberately long-lived and their data directory is
/// a tmpfs, so a run that dies before its teardown costs memory until
/// something clears it.
///
/// A broken sweep is not worth failing a test run over: a failure inside
/// Docker itself (as opposed to a failed statement, which is a normal outcome
/// here) is caught, printed, and answered with whatever this had already
/// dropped. Catching only the engine's own failure type, not [Object], means
/// a bug in this file still reaches the developer.
Future<List<String>> dropStaleSuiteDatabases({
  required DockerEngine engine,
  required String containerId,
  required String rootPassword,
  required DateTime now,
  required StateDir stateDir,
  Duration staleAfter = defaultStaleAfter,
  Duration markerStaleAfter = defaultMarkerStaleAfter,
}) async {
  final dropped = <String>[];

  // LIKE 'test%' rather than an escaped underscore: a backslash inside a
  // MySQL string literal is an escape character, which makes 'test\_%' a
  // thing to squint at for no gain. What a name this module produced
  // actually looks like is createdAtOf's business, and it is consulted
  // below either way.
  //
  // PROCESSLIST needs the PROCESS privilege, which root has. It narrows the
  // list rather than guaranteeing anything: MySQL would drop a database
  // somebody connected to a moment later just the same, so the marker is
  // what protects a live suite.
  ExecResult listing;
  try {
    listing = await runMysql(
      engine,
      containerId,
      rootPassword: rootPassword,
      sql:
          'SELECT s.SCHEMA_NAME FROM information_schema.SCHEMATA s '
          "WHERE s.SCHEMA_NAME LIKE 'test%' "
          'AND NOT EXISTS (SELECT 1 FROM information_schema.PROCESSLIST p '
          'WHERE p.DB = s.SCHEMA_NAME)',
    );
  } on EngineError catch (e) {
    _printCouldNotSweep(containerId, e);
    return dropped;
  }
  if (listing.exitCode != 0) {
    // ignore: avoid_print
    print(
      'rig_mysql: could not list suite databases in container $containerId '
      'to sweep them: ${listing.output}',
    );
    return dropped;
  }

  for (final name in listing.output.split('\n')) {
    final candidate = name.trim();
    if (candidate.isEmpty) continue;

    final marker = suiteMarkerFile(
      stateDir: stateDir,
      kind: 'mysql',
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

    ExecResult dropResult;
    try {
      dropResult = await _dropDatabase(
        engine,
        containerId,
        rootPassword,
        candidate,
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
        'rig_mysql: skipped stale suite database $candidate in container '
        '$containerId because the drop did not succeed: ${dropResult.output}',
      );
      continue;
    }

    _clearMarker(stateDir, containerId, candidate);
    dropped.add(candidate);
    // ignore: avoid_print
    print(
      'rig_mysql: dropped stale suite database $candidate in container '
      '$containerId',
    );
  }
  return dropped;
}

Future<ExecResult> _dropDatabase(
  DockerEngine engine,
  String containerId,
  String rootPassword,
  String database,
) => runMysql(
  engine,
  containerId,
  rootPassword: rootPassword,
  sql: 'DROP DATABASE IF EXISTS ${mysqlIdentifier(database)}',
);

void _clearMarker(StateDir stateDir, String containerId, String database) {
  final marker = suiteMarkerFile(
    stateDir: stateDir,
    kind: 'mysql',
    containerId: containerId,
    resource: database,
  );
  try {
    if (marker.existsSync()) marker.deleteSync();
  } on FileSystemException {
    // Nothing to undo if it cannot be removed.
  }
}

void _printCouldNotSweep(String containerId, EngineError e) {
  // ignore: avoid_print
  print(
    'rig_mysql: could not sweep stale suite databases in container '
    '$containerId because Docker could not run the command: $e',
  );
}
