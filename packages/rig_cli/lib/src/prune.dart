import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rig/engine.dart';
import 'package:rig/rig.dart';

/// Remove containers rig is holding.
///
/// Shared and dedicated containers are held to different cutoffs because
/// their age means different things. A shared container's age is how long
/// reuse across runs has been paying off, so a bare prune only takes one
/// past [olderThan] (seven days by default) — long enough that removing a
/// shared container a suite is using right now is unlikely, though not
/// impossible: age is when Docker created the container, not when it was
/// last used, since Docker exposes no such time.
///
/// A dedicated container means something else entirely: it is created for
/// one suite and removed at that suite's teardown, so its age is
/// essentially that suite's runtime. One still around past
/// [dedicatedOlderThan] (one hour by default) has outlived any plausible
/// test suite — the only way it gets that old is that its suite was killed
/// before teardown ran, so it can only be a leak. That said, the same
/// caveat as [olderThan] applies: if some suite's run genuinely takes
/// longer than an hour, a bare prune while it is still running will take
/// its dedicated container out from under it.
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
  stateDir.ensure();

  final held = await rigContainers(engine);

  final failedIds = _markedAsFailed(stateDir);
  final doomed = held.where((c) {
    final labels = RigLabels.tryParse(c.labels);
    if (labels == null) return false; // not rig's, never touch it
    if (failedOnly) return failedIds.contains(c.id);
    if (all) return true;
    if (labels.lifetime == Lifetime.dedicated) {
      return now.difference(c.created) > dedicatedOlderThan;
    }
    return now.difference(c.created) > olderThan;
  }).toList();

  var sharedRemoved = 0;
  var dedicatedRemoved = 0;
  for (final container in doomed) {
    await engine.removeContainer(container.id);
    final labels = RigLabels.tryParse(container.labels);
    final summary = labels?.summary ?? container.image;
    if (labels?.lifetime == Lifetime.dedicated) {
      dedicatedRemoved++;
    } else {
      sharedRemoved++;
    }
    out('removed ${_shortId(container.id)}  $summary');
  }

  // Networks only after containers: removing a container this run just
  // doomed is what frees the network it was on, so trying networks first
  // would hit "still in use" for networks this same run was about to clear.
  final networkResult = await _pruneNetworks(engine, out);

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

  // Every container this run knows the daemon still has, minus whatever it
  // just removed above — a container's tmpfs PGDATA goes with it, so a
  // suite marker for anything else has nothing left to protect. This runs
  // unconditionally, the same way clearing a vanished container's failure
  // marker does: gating it behind a flag would let orphaned directories pile
  // up through ordinary use.
  final knownContainerIds = {for (final c in held) c.id}
    ..removeAll(doomed.map((c) => c.id));
  final clearedSuiteDirs = _clearSuiteDirs(
    stateDir,
    knownIds: knownContainerIds,
  );

  if (doomed.isEmpty &&
      networkResult.removed == 0 &&
      clearedMarkers == 0 &&
      clearedSuiteDirs == 0) {
    out('Nothing to remove.');
  } else {
    final extras = [
      if (networkResult.removed > 0) '${networkResult.removed} network(s)',
      if (clearedMarkers > 0) '$clearedMarkers stale marker(s)',
      if (clearedSuiteDirs > 0)
        '$clearedSuiteDirs stale suite '
            'director${clearedSuiteDirs == 1 ? 'y' : 'ies'}',
    ];
    final suffix = extras.isEmpty ? '' : ' and ${extras.join(' and ')}';
    final breakdown = doomed.isEmpty
        ? ''
        : ' ($sharedRemoved shared, $dedicatedRemoved dedicated)';
    out('Removed ${doomed.length} container(s)$breakdown$suffix.');
  }

  // Never silent: a network Docker refuses to drop is exactly the kind of
  // thing `--all` is supposed to surface, not swallow.
  if (networkResult.stillInUse.isNotEmpty) {
    out(
      '${networkResult.stillInUse.length} network(s) still in use, not '
      'removed: ${networkResult.stillInUse.join(', ')}',
    );
  }

  return 0;
}

typedef _NetworkPruneResult = ({int removed, List<String> stillInUse});

/// Removes every rig-labelled network with no containers attached.
///
/// Docker itself is the source of truth for "in use": rather than trusting
/// [NetworkSummary.hasActiveEndpoints] from the listing (which could be
/// stale relative to the containers this same run just removed, or simply
/// wrong for a network this run has no reason to touch), every rig network
/// gets an attempt, and [DockerEngine.removeNetwork]'s own answer decides
/// which bucket it lands in.
Future<_NetworkPruneResult> _pruneNetworks(
  DockerEngine engine,
  void Function(String) out,
) async {
  final networks = await engine.listNetworks(
    filters: {
      'label': [rigMarkerLabel],
    },
  );

  var removed = 0;
  final stillInUse = <String>[];
  for (final network in networks) {
    if (await engine.removeNetwork(network.id)) {
      removed++;
      out('removed network ${network.name}');
    } else {
      stillInUse.add(network.name);
    }
  }
  return (removed: removed, stillInUse: stillInUse);
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

/// Removes every container-id subdirectory, under every kind directory in
/// the markers root, whose name is not in [knownIds], and reports how many
/// it removed.
///
/// Deliberately does not know what any kind means, or even what kinds
/// exist: it lists whatever subdirectories `markers/` happens to have and
/// sweeps each one's container-id children the same way. That is the whole
/// point of the `markers/<kind>/<containerId>/<name>` layout — a module
/// adding a new kind needs no change here. Only prune ever looks at a
/// container that is no longer live, so only prune can tell a marker
/// directory left behind by a `SIGKILL`ed suite from one still protecting a
/// resource that exists.
int _clearSuiteDirs(StateDir stateDir, {required Set<String> knownIds}) {
  final markersRoot = Directory(p.join(stateDir.root.path, 'markers'));
  if (!markersRoot.existsSync()) return 0;
  var cleared = 0;
  for (final kindDir in markersRoot.listSync()) {
    if (kindDir is! Directory) continue;
    for (final entry in kindDir.listSync()) {
      if (entry is! Directory) continue;
      if (knownIds.contains(p.basename(entry.path))) continue;
      entry.deleteSync(recursive: true);
      cleared++;
    }
    // An empty kind directory left behind is harmless — the next marker of
    // that kind recreates it — so there is nothing gained by also removing
    // it here, and doing so would just be more code sharing this method's
    // one job.
  }
  return cleared;
}
