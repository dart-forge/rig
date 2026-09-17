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
    throw StateError(
      'Could not create the database for this suite ($database), so the '
      'suite would have run against a shared one.\n${result.output}',
    );
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
  // No throw on failure: teardown also runs after a failure, and a database
  // that is already gone is the state teardown was asking for.
  await _psql(
    engine,
    containerId,
    user,
    adminDatabase,
    'DROP DATABASE IF EXISTS $database${force ? ' WITH (FORCE)' : ''}',
  );

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
/// considered abandoned, and that carry no marker — and returns the ones it
/// dropped.
///
/// Shared containers are deliberately long-lived, and each suite database is a
/// clone of template0 sitting in a tmpfs — so a run that dies before its
/// teardown costs memory until something clears it.
///
/// Nothing here throws. A broken sweep is not worth failing a test run over;
/// see [createSuiteDatabase] for what actually keeps a suite's own database
/// isolated.
Future<List<String>> dropStaleSuiteDatabases({
  required DockerEngine engine,
  required String containerId,
  required String user,
  required String adminDatabase,
  required DateTime now,
  required StateDir stateDir,
  Duration staleAfter = defaultStaleAfter,
}) async {
  // Age alone is not evidence: a suite holding a lease may simply be between
  // connections. Neither is "nobody connected" alone, for the same reason.
  // What actually distinguishes a live suite is the marker
  // createSuiteDatabase writes and dropSuiteDatabase removes — the
  // filesystem is the one channel every isolate in a `dart test` run can
  // see, unlike anything held in memory.
  final listing = await _psql(
    engine,
    containerId,
    user,
    adminDatabase,
    "SELECT d.datname FROM pg_database d "
    "WHERE d.datname LIKE 'test\\_%' "
    "AND NOT EXISTS (SELECT 1 FROM pg_stat_activity a "
    "WHERE a.datname = d.datname)",
  );
  if (listing.exitCode != 0) return const [];

  final cutoff = now.toUtc().subtract(staleAfter);
  final dropped = <String>[];

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

    // A marker means some suite still claims this database, however long it
    // has been since anyone connected to it — a suite between connections is
    // exactly what the marker exists to protect. The age check above is what
    // still catches a database whose marker has not been written yet (the
    // instant between CREATE DATABASE and the marker being written) rather
    // than condemning it as if it were abandoned.
    if (suiteMarkerFile(
      stateDir: stateDir,
      containerId: containerId,
      database: candidate,
    ).existsSync()) {
      continue;
    }

    await dropSuiteDatabase(
      engine: engine,
      containerId: containerId,
      user: user,
      adminDatabase: adminDatabase,
      database: candidate,
      stateDir: stateDir,
      force: false,
    );
    dropped.add(candidate);
  }
  return dropped;
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
