import 'dart:io';

import 'package:path/path.dart' as p;

import 'engine/current.dart';
import 'engine/docker_engine.dart';
import 'lease/state_dir.dart';
import 'spec/container_spec.dart';
import 'spec/labels.dart';

/// One container [pruneContainers] removed: enough to name it in a report.
final class PrunedContainer {
  const PrunedContainer({required this.id, required this.summary});

  /// The container's full id, as Docker returns it.
  final String id;

  /// The human-readable label `rig ls` would show for it.
  final String summary;
}

/// What [pruneContainers] did.
///
/// Everything a caller would need to report what happened lives here,
/// because the point of this type is that [pruneContainers] itself prints
/// nothing — a caller that wants to tell a human what happened formats
/// this, rather than the library deciding how.
final class PruneResult {
  const PruneResult({
    required this.removedContainers,
    required this.sharedRemoved,
    required this.dedicatedRemoved,
    required this.removedNetworks,
    required this.networksStillInUse,
    required this.clearedFailureMarkers,
    required this.clearedMarkerDirectories,
  });

  /// The containers removed this run, in removal order.
  final List<PrunedContainer> removedContainers;

  /// How many of [removedContainers] were shared.
  final int sharedRemoved;

  /// How many of [removedContainers] were dedicated.
  final int dedicatedRemoved;

  /// Names of the rig networks removed this run, in removal order.
  final List<String> removedNetworks;

  /// Names of rig's networks Docker refused to remove because a container
  /// is still attached.
  ///
  /// Never left for a caller to lose track of: a network Docker refuses to
  /// drop is exactly the kind of thing `--all` is supposed to surface, not
  /// swallow. This list is how a caller reports the refusal instead of it
  /// passing unnoticed.
  final List<String> networksStillInUse;

  /// How many stale failure markers (from `--failed`, or from a container
  /// that vanished on its own) were cleared.
  final int clearedFailureMarkers;

  /// How many stale marker directories — a module's claim on something
  /// inside a container that no longer exists — were cleared.
  final int clearedMarkerDirectories;
}

/// Remove containers rig is holding, and the networks and marker files that
/// exist only to serve them, and report what was done.
///
/// [engine] defaults to [currentEngine], [stateDir] to [StateDir.forUser],
/// and [now] to the system clock, so `await pruneContainers()` from a test
/// or a script means the same thing as a bare `rig prune`.
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
///
/// **[all] is not the safe choice, and calling it from a suite is not like
/// typing `--all` at a terminal.** A person doing that is about to read the
/// output and can judge whether now is a safe time to run it. Code that
/// calls `pruneContainers(all: true)` has no such judgment, and the
/// containers it removes are *certainly* in use by something — a dedicated
/// container some other suite is mid-run with, or a shared container a
/// suite in a completely different project is using this instant, since
/// containers are shared across project boundaries, not only across suites
/// in this one. Reach for it only where that is exactly what you mean;
/// otherwise leave the age-based defaults to do the safe thing.
///
/// One more hazard, which has nothing to do with [all]: this asks [engine]
/// what containers exist and treats every marker directory naming a
/// container it does not know as orphaned. That is right when the daemon is
/// the one those containers live on, and quietly wrong when it is not. Prune
/// against the wrong daemon — a `DOCKER_HOST` pointing elsewhere, a
/// different context — and the markers protecting live containers on the
/// right one are removed, which leaves the resources they were claiming
/// unprotected from a later sweep. Nothing detects this; the markers simply
/// look like garbage. Pass an [engine] only when you know which daemon it
/// is talking to.
Future<PruneResult> pruneContainers({
  Duration olderThan = const Duration(days: 7),
  Duration dedicatedOlderThan = const Duration(hours: 1),
  bool all = false,
  bool failedOnly = false,
  DockerEngine? engine,
  StateDir? stateDir,
  DateTime? now,
}) async {
  final resolvedEngine = engine ?? await currentEngine();
  final resolvedStateDir = stateDir ?? StateDir.forUser();
  final resolvedNow = now ?? DateTime.now();

  resolvedStateDir.ensure();

  final held = await rigContainers(resolvedEngine);

  final failedIds = _markedAsFailed(resolvedStateDir);
  final doomed = held.where((c) {
    final labels = RigLabels.tryParse(c.labels);
    if (labels == null) return false; // not rig's, never touch it
    if (failedOnly) return failedIds.contains(c.id);
    if (all) return true;
    if (labels.lifetime == Lifetime.dedicated) {
      return resolvedNow.difference(c.created) > dedicatedOlderThan;
    }
    return resolvedNow.difference(c.created) > olderThan;
  }).toList();

  final removedContainers = <PrunedContainer>[];
  var sharedRemoved = 0;
  var dedicatedRemoved = 0;
  for (final container in doomed) {
    await resolvedEngine.removeContainer(container.id);
    final labels = RigLabels.tryParse(container.labels);
    final summary = labels?.summary ?? container.image;
    if (labels?.lifetime == Lifetime.dedicated) {
      dedicatedRemoved++;
    } else {
      sharedRemoved++;
    }
    removedContainers.add(PrunedContainer(id: container.id, summary: summary));
  }

  // Networks only after containers: removing a container this run just
  // doomed is what frees the network it was on, so trying networks first
  // would hit "still in use" for networks this same run was about to clear.
  final networkResult = await _pruneNetworks(resolvedEngine);

  final clearedFailureMarkers = _clearMarkers(
    resolvedStateDir,
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
  final clearedMarkerDirectories = _clearSuiteDirs(
    resolvedStateDir,
    knownIds: knownContainerIds,
  );

  return PruneResult(
    removedContainers: removedContainers,
    sharedRemoved: sharedRemoved,
    dedicatedRemoved: dedicatedRemoved,
    removedNetworks: networkResult.removed,
    networksStillInUse: networkResult.stillInUse,
    clearedFailureMarkers: clearedFailureMarkers,
    clearedMarkerDirectories: clearedMarkerDirectories,
  );
}

typedef _NetworkPruneResult = ({List<String> removed, List<String> stillInUse});

/// Removes every rig-labelled network with no containers attached.
///
/// Docker itself is the source of truth for "in use": rather than trusting
/// [NetworkSummary.hasActiveEndpoints] from the listing (which could be
/// stale relative to the containers this same run just removed, or simply
/// wrong for a network this run has no reason to touch), every rig network
/// gets an attempt, and [DockerEngine.removeNetwork]'s own answer decides
/// which bucket it lands in.
Future<_NetworkPruneResult> _pruneNetworks(DockerEngine engine) async {
  final networks = await engine.listNetworks(
    filters: {
      'label': [rigMarkerLabel],
    },
  );

  final removed = <String>[];
  final stillInUse = <String>[];
  for (final network in networks) {
    if (await engine.removeNetwork(network.id)) {
      removed.add(network.name);
    } else {
      stillInUse.add(network.name);
    }
  }
  return (removed: removed, stillInUse: stillInUse);
}

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
