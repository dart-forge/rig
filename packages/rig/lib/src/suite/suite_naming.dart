import 'dart:io';
import 'dart:math';

import 'suite_markers.dart';

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
/// and the minute stamp is how an abandoned one is recognised later: neither
/// Postgres nor MySQL records when a database was created, so the name has
/// to. Without it there would be no way to tell a database a crashed suite
/// left behind from one another suite created a moment ago.
String suiteDatabaseName({
  required String project,
  required DateTime now,
  required String token,
}) {
  final slug = _slugOf(project);
  final stamp = minuteStampOf(now);
  // Postgres caps identifiers at 63 characters and MySQL at 64, so one
  // number serves both. The stamp and the token have to survive whatever the
  // project is called, so the slug is what gives way.
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

/// The minute stamp out of a name [suiteDatabaseName] produced, or null when
/// the name did not come from there.
///
/// A generator that can emit a name its own parser rejects leaves databases
/// nobody ever cleans up, so the pair is worth pinning directly rather than
/// only through the sweep.
DateTime? createdAtOf(String database) {
  final match = RegExp(r'^test_.*_(\d+)_[0-9a-f]{8}$').firstMatch(database);
  if (match == null) return null;
  final minutes = int.tryParse(match.group(1)!);
  if (minutes == null) return null;
  return DateTime.fromMillisecondsSinceEpoch(minutes * 60000, isUtc: true);
}

/// Whether [database] is a suite database that can be taken back.
///
/// Three things have to hold. The name has to be one [suiteDatabaseName]
/// produced — anything else belongs to whoever made it. The database has to
/// be older than [staleAfter], judged by the latest moment its name allows
/// rather than the earliest, because the stamp is floored to the minute and
/// being wrong the other way drops a database whose own suite has not
/// connected yet. And [marker] must have stopped claiming it.
///
/// Age alone is not evidence and "nobody connected" alone is not either: a
/// suite holding a lease may simply be between connections. The marker is
/// what actually distinguishes a live suite, which is why it is the last
/// word here.
bool isReclaimableSuiteDatabase({
  required String database,
  required DateTime now,
  required File marker,
  Duration staleAfter = defaultStaleAfter,
  Duration markerStaleAfter = defaultMarkerStaleAfter,
}) {
  final createdAt = createdAtOf(database);
  if (createdAt == null) return false;

  final createdNoLaterThan = createdAt.add(const Duration(minutes: 1));
  if (!createdNoLaterThan.isBefore(now.toUtc().subtract(staleAfter))) {
    return false;
  }

  return !markerStillClaims(
    marker,
    now: now,
    markerStaleAfter: markerStaleAfter,
  );
}
