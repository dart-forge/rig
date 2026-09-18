import 'package:rig/engine.dart';
import 'package:rig/rig.dart';

/// Removes containers rig is holding by calling [pruneContainers], and
/// prints what it did.
///
/// This is the formatting layer only: every decision about what to remove
/// lives in [pruneContainers] now, so a caller that does not want a command
/// line — a script, a test suite's own teardown — can call that directly
/// and get [PruneResult] back instead of printed lines.
Future<int> runPrune({
  required DockerEngine engine,
  required StateDir stateDir,
  required void Function(String) out,
  required DateTime now,
  Duration olderThan = const Duration(days: 7),
  Duration dedicatedOlderThan = const Duration(hours: 1),
  bool all = false,
  bool failedOnly = false,
}) async {
  final result = await pruneContainers(
    engine: engine,
    stateDir: stateDir,
    now: now,
    olderThan: olderThan,
    dedicatedOlderThan: dedicatedOlderThan,
    all: all,
    failedOnly: failedOnly,
  );

  for (final container in result.removedContainers) {
    out('removed ${_shortId(container.id)}  ${container.summary}');
  }
  for (final name in result.removedNetworks) {
    out('removed network $name');
  }

  final removedCount = result.removedContainers.length;
  if (removedCount == 0 &&
      result.removedNetworks.isEmpty &&
      result.clearedFailureMarkers == 0 &&
      result.clearedMarkerDirectories == 0) {
    out('Nothing to remove.');
  } else {
    // "failure marker" and "marker directory" are deliberately different
    // words: the first is the file recording that a run failed, the second is
    // what a module writes to claim something inside a container. Calling
    // both "marker" made the line ambiguous once modules got their own.
    final extras = [
      if (result.removedNetworks.isNotEmpty)
        '${result.removedNetworks.length} network(s)',
      if (result.clearedFailureMarkers > 0)
        '${result.clearedFailureMarkers} stale failure marker(s)',
      if (result.clearedMarkerDirectories > 0)
        '${result.clearedMarkerDirectories} stale marker '
            'director${result.clearedMarkerDirectories == 1 ? 'y' : 'ies'}',
    ];
    final suffix = switch (extras.length) {
      0 => '',
      1 => ' and ${extras.single}',
      // Commas up to the last one, so three items do not read as a chain of
      // "and"s.
      _ =>
        ', ${extras.take(extras.length - 1).join(', ')} '
            'and ${extras.last}',
    };
    final breakdown = removedCount == 0
        ? ''
        : ' (${result.sharedRemoved} shared, ${result.dedicatedRemoved} '
              'dedicated)';
    out('Removed $removedCount container(s)$breakdown$suffix.');
  }

  // Never silent: a network Docker refuses to drop is exactly the kind of
  // thing `--all` is supposed to surface, not swallow.
  if (result.networksStillInUse.isNotEmpty) {
    out(
      '${result.networksStillInUse.length} network(s) still in use, not '
      'removed: ${result.networksStillInUse.join(', ')}',
    );
  }

  return 0;
}

/// Docker's real container ids are 64 hex characters; the first 12 are
/// enough to identify one on the command line. Test doubles may hand out
/// shorter ids, so this never assumes the id is long enough to truncate.
String _shortId(String id) => id.length > 12 ? id.substring(0, 12) : id;
