import 'dart:math';

import 'package:rig/engine.dart';

/// How long a suite database has to sit unused before it is treated as
/// abandoned.
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
  final slug = project.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
  final stamp = minuteStampOf(now);
  // Identifiers cap at 63 characters, and the stamp and token have to survive
  // whatever the project is called.
  final room = 63 - 'test__${stamp}_$token'.length;
  final trimmed = slug.length > room ? slug.substring(0, room) : slug;
  return 'test_${trimmed}_${stamp}_$token'.replaceAll(RegExp(r'_+'), '_');
}

/// Creates [database] for one suite inside a container others are sharing.
Future<void> createSuiteDatabase({
  required DockerEngine engine,
  required String containerId,
  required String user,
  required String adminDatabase,
  required String database,
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
}

/// Drops [database]. Silent when it is already gone.
Future<void> dropSuiteDatabase({
  required DockerEngine engine,
  required String containerId,
  required String user,
  required String adminDatabase,
  required String database,
}) async {
  // FORCE so a connection a test forgot to close cannot block teardown, and no
  // throw on failure: teardown also runs after a failure, and a database that
  // is already gone is the state teardown was asking for.
  await _psql(
    engine,
    containerId,
    user,
    adminDatabase,
    'DROP DATABASE $database WITH (FORCE)',
  );
}

/// Drops suite databases nobody is connected to that are older than
/// [staleAfter], and returns the ones it dropped.
///
/// Shared containers are deliberately long-lived, and each suite database is a
/// clone of template0 sitting in a tmpfs — so a run that dies before its
/// teardown costs memory until something clears it.
Future<List<String>> dropStaleSuiteDatabases({
  required DockerEngine engine,
  required String containerId,
  required String user,
  required String adminDatabase,
  required DateTime now,
  Duration staleAfter = defaultStaleAfter,
}) async {
  // Age alone is not evidence: a suite holding a lease may simply be between
  // connections. Both conditions have to hold.
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

    final createdAt = _createdAtOf(candidate);
    if (createdAt == null || !createdAt.isBefore(cutoff)) continue;

    await dropSuiteDatabase(
      engine: engine,
      containerId: containerId,
      user: user,
      adminDatabase: adminDatabase,
      database: candidate,
    );
    dropped.add(candidate);
  }
  return dropped;
}

/// The minute stamp out of a name this module produced, or null when the name
/// did not come from here.
DateTime? _createdAtOf(String database) {
  final match = RegExp(r'^test_.*_(\d+)_[^_]+$').firstMatch(database);
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
