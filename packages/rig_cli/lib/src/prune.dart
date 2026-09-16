import 'dart:io';

import 'package:rig/engine.dart';
import 'package:rig/rig.dart';

/// Remove containers rig is holding.
///
/// By default only shared containers past [olderThan]: a dedicated container
/// belongs to whoever created it, and may be in use by a suite running right
/// now even if it looks old.
Future<int> runPrune({
  required DockerEngine engine,
  required StateDir stateDir,
  required void Function(String) out,
  required DateTime now,
  Duration olderThan = const Duration(days: 7),
  bool all = false,
  bool failedOnly = false,
}) async {
  stateDir.ensure();

  final held = await rigContainers(engine);

  final failedIds = _markedAsFailed(stateDir);
  final doomed = held.where((c) {
    final labels = RigLabels.tryParse(c.labels);
    if (labels == null) return false; // not rig's, never touch it
    if (failedOnly) return failedIds.contains(c.id);
    if (all) return true;
    if (labels.lifetime == Lifetime.dedicated) return false;
    return now.difference(c.created) > olderThan;
  }).toList();

  for (final container in doomed) {
    await engine.removeContainer(container.id);
    final summary =
        RigLabels.tryParse(container.labels)?.summary ?? container.image;
    out('removed ${_shortId(container.id)}  $summary');
  }

  final clearedMarkers = _clearMarkers(
    stateDir,
    forIds: {
      ...doomed.map((c) => c.id),
      // A marker whose container is gone has nothing left to describe,
      // whatever flags this run was given. Gating this on --failed would let
      // markers pile up silently through ordinary use.
      ...failedIds.where((id) => !held.any((c) => c.id == id)),
    },
  );

  if (doomed.isEmpty && clearedMarkers == 0) {
    out('Nothing to remove.');
  } else {
    final markers = clearedMarkers > 0
        ? ' and $clearedMarkers stale marker(s)'
        : '';
    out('Removed ${doomed.length} container(s)$markers.');
  }
  return 0;
}

/// Docker's real container ids are 64 hex characters; the first 12 are
/// enough to identify one on the command line. Test doubles may hand out
/// shorter ids, so this never assumes the id is long enough to truncate.
String _shortId(String id) => id.length > 12 ? id.substring(0, 12) : id;

Set<String> _markedAsFailed(StateDir stateDir) {
  if (!stateDir.failedDir.existsSync()) return const {};
  return stateDir.failedDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .map((f) => f.uri.pathSegments.last.replaceAll('.json', ''))
      .toSet();
}

int _clearMarkers(StateDir stateDir, {required Set<String> forIds}) {
  var cleared = 0;
  for (final id in forIds) {
    final marker = stateDir.failedMarker(id);
    if (marker.existsSync()) {
      marker.deleteSync();
      cleared++;
    }
  }
  return cleared;
}
