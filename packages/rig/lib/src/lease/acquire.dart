import 'dart:convert';

import '../engine/docker_engine.dart';
import '../spec/container_spec.dart';
import '../spec/labels.dart';
import '../spec/spec_hash.dart';
import '../wait/ready.dart';
import 'lock.dart';
import 'state_dir.dart';

/// A container that exists, is running, and is ready to use.
final class AcquiredContainer {
  const AcquiredContainer({
    required this.containerId,
    required this.host,
    required this.hostPorts,
    required this.lifetime,
    required this.reused,
    required this.hash,
  });

  final String containerId;
  final String host;

  /// Container port to the host port Docker chose.
  final Map<int, int> hostPorts;

  final Lifetime lifetime;

  /// True when this container was already running or stopped and got reused
  /// rather than created.
  final bool reused;

  final String hash;
}

/// Get a running, ready container for [spec].
///
/// Shared specs look for one Docker already holds, under a lock so two
/// suites cannot both decide to create it. The lock covers only the create
/// and the start: waiting for readiness happens after it is released, because
/// a wait strategy is safe to run any number of times and holding the lock
/// through a 60 second wait would stop every other suite.
///
/// Ensuring the image is present happens before the lock is taken, on the
/// dedicated path too even though that path never locks at all. The lock's
/// own timeouts assume it is held only across a create and a start — a few
/// seconds — and a cold pull of a large image routinely takes longer than
/// that, which would make every other shared suite fail with `LockTimeout`
/// mid-pull, or start treating a live lock as stale. `pullImage` is
/// idempotent and Docker coalesces concurrent pulls of the same reference,
/// so nothing is lost by asking before knowing whether this call will end up
/// reusing a container instead of creating one.
Future<AcquiredContainer> acquireContainer({
  required ContainerSpec spec,
  required DockerEngine engine,
  required StateDir stateDir,
  required String project,
  String host = '127.0.0.1',
  Now now = DateTime.now,
  Sleeper sleep = _delay,
}) async {
  stateDir.ensure();

  final hash = specHash(spec);
  final labels = buildRigLabels(spec: spec, hash: hash, project: project);

  await _ensureImage(spec.image, engine);

  final placed = spec.lifetime == Lifetime.dedicated
      // A private container cannot collide with anyone, so there is nothing
      // to coordinate and no reason to queue behind other suites.
      ? await _create(spec, labels, engine)
      : await withExclusiveLock(
          stateDir.lockPath(hash),
          () => _findOrCreate(spec, labels, hash, engine),
          now: now,
          sleep: sleep,
        );

  final inspected = await engine.inspectContainer(placed.id);
  final acquired = AcquiredContainer(
    containerId: placed.id,
    host: host,
    hostPorts: inspected.hostPorts,
    lifetime: spec.lifetime,
    reused: placed.reused,
    hash: hash,
  );

  try {
    await awaitReady(
      strategy: spec.waitFor,
      engine: engine,
      target: ReadyTarget(
        containerId: acquired.containerId,
        host: host,
        hostPortOf: (containerPort) => acquired.hostPorts[containerPort],
      ),
      now: now,
      sleep: sleep,
    );
  } on Object catch (error) {
    // Leave the container alone: it is the only evidence of why it failed.
    // Record it instead, since Docker cannot add a label after creation.
    _markFailed(stateDir, acquired.containerId, spec, hash, error, now());
    rethrow;
  }

  return acquired;
}

typedef _Placed = ({String id, bool reused});

Future<_Placed> _findOrCreate(
  ContainerSpec spec,
  Map<String, String> labels,
  String hash,
  DockerEngine engine,
) async {
  final candidates = await engine.listContainers(
    filters: {
      'label': ['$rigHashLabel=$hash', '$rigLifetimeLabel=shared'],
    },
  );

  final running = candidates.where((c) => c.state == 'running');
  if (running.isNotEmpty) {
    return (id: running.first.id, reused: true);
  }

  if (candidates.isNotEmpty) {
    // Starting a stopped container is cheaper than creating one, and keeps
    // whatever state a previous run left in it.
    final id = candidates.first.id;
    await engine.startContainer(id);
    return (id: id, reused: true);
  }

  return _create(spec, labels, engine);
}

Future<_Placed> _create(
  ContainerSpec spec,
  Map<String, String> labels,
  DockerEngine engine,
) async {
  final id = await engine.createContainer(spec, labels);
  await engine.startContainer(id);
  return (id: id, reused: false);
}

/// The image has to be there before create can succeed, but this runs
/// before any lock is taken — see [acquireContainer]'s doc comment.
Future<void> _ensureImage(String image, DockerEngine engine) async {
  if (!await engine.imageExists(image)) {
    await engine.pullImage(image);
  }
}

void _markFailed(
  StateDir stateDir,
  String containerId,
  ContainerSpec spec,
  String hash,
  Object error,
  DateTime at,
) {
  try {
    stateDir
        .failedMarker(containerId)
        .writeAsStringSync(
          jsonEncode({
            'containerId': containerId,
            'image': spec.image,
            'hash': hash,
            'failedAt': at.toUtc().toIso8601String(),
            'reason': error.toString(),
          }),
        );
  } on Object {
    // Recording the failure is a convenience for `rig prune`. If it cannot be
    // written, the real error still reaches the caller.
  }
}

Future<void> _delay(Duration d) => Future<void>.delayed(d);
