import 'dart:math';

import 'package:rig/engine.dart';

/// How long a suite database has to sit unused before it is treated as
/// abandoned.
///
/// Well above a minute on purpose: a name carries the minute it was created
/// in, floored, so anything near that resolution cannot distinguish a
/// database abandoned an hour ago from one created moments before a minute
/// boundary.
const Duration defaultStaleAfter = Duration(hours: 1);

final Random _tokens = Random();

/// When this process started, for callers that do not supply a bound.
///
/// Nothing this process created can be older than this, which is what makes
/// the sweep structurally unable to touch a database belonging to a suite
/// running alongside it. Age and idleness alone cannot tell those apart: a
/// suite between two connections has no row in `pg_stat_activity`, so the
/// guard meant to protect it is satisfied by the very state it is meant to
/// catch.
final DateTime _processStartedAt = DateTime.now().toUtc();

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
    'DROP DATABASE IF EXISTS $database WITH (FORCE)',
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
  DateTime? processStartedAt,
}) async {
  // Both ends of the comparison are injectable. Taking `now` from the caller
  // and the process bound from the real clock would tie every test with a
  // frozen clock to wall-clock time, which is how a test of a destructive
  // operation becomes flaky.
  final startedAt = processStartedAt ?? _processStartedAt;

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

    final createdAt = createdAtOf(candidate);
    if (createdAt == null) continue;

    // The stamp is the minute the database was created in, floored, so the
    // database can be up to a minute younger than it claims. Judge it by the
    // latest moment it could have been created, never the earliest: being
    // wrong in the other direction would drop a database whose own suite has
    // not connected to it yet.
    final createdNoLaterThan = createdAt.add(const Duration(minutes: 1));
    if (!createdNoLaterThan.isBefore(cutoff)) continue;

    // Never a database this process could have created. Suites in this run
    // share the process, so this rules them out by construction instead of
    // relying on the age margin being generous enough.
    if (!createdNoLaterThan.isBefore(startedAt)) continue;

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
