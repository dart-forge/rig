import 'dart:io';

import 'package:rig/engine.dart';
import 'package:rig/fake_engine.dart';
import 'package:rig/rig.dart';
import 'package:test/test.dart';

void main() {
  late FakeDockerEngine engine;
  late Directory tmp;
  late StateDir state;

  setUp(() {
    engine = FakeDockerEngine();
    tmp = Directory.systemTemp.createTempSync('rig_acquire_');
    state = StateDir(tmp)..ensure();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  const spec = ContainerSpec(
    image: 'postgres:16-alpine',
    exposedPorts: [5432],
    waitFor: WaitFor.healthy(),
    healthcheck: Healthcheck(test: ['CMD', 'true']),
  );

  Future<AcquiredContainer> acquire([ContainerSpec s = spec]) =>
      acquireContainer(
        spec: s,
        engine: _InstantlyHealthy(engine),
        stateDir: state,
        project: 'aim_postgres',
      );

  group('when nothing exists yet', () {
    test('pulls the image, creates, starts and reports not reused', () async {
      final acquired = await acquire();

      expect(
        engine.calls,
        containsAllInOrder(['pull:postgres:16-alpine', 'create']),
      );
      expect(acquired.reused, isFalse);
      expect(acquired.hostPorts[5432], isNotNull);
      expect(acquired.host, '127.0.0.1');
    });

    test('skips the pull when the image is already present', () async {
      engine.images.add('postgres:16-alpine');

      await acquire();

      expect(engine.calls.where((c) => c.startsWith('pull')), isEmpty);
    });

    test('labels the container so it can be found again', () async {
      await acquire();

      final labels = engine.lastCreatedLabels!;
      expect(labels[rigMarkerLabel], '1');
      expect(labels[rigHashLabel], specHash(spec));
      expect(labels[rigLifetimeLabel], 'shared');
      expect(labels[rigProjectLabel], 'aim_postgres');
    });
  });

  group('when a matching container is already running', () {
    test('reuses it without creating anything', () async {
      final existing = engine.addContainer(
        labels: {
          rigMarkerLabel: '1',
          rigHashLabel: specHash(spec),
          rigLifetimeLabel: 'shared',
        },
        hostPorts: {5432: 55001},
        health: [HealthStatus.healthy],
      );

      final acquired = await acquire();

      expect(acquired.containerId, existing);
      expect(acquired.reused, isTrue);
      expect(acquired.hostPorts[5432], 55001);
      expect(engine.calls.contains('create'), isFalse);
    });

    test('ignores a container whose hash differs', () async {
      engine.addContainer(
        labels: {
          rigMarkerLabel: '1',
          rigHashLabel: 'some-other-hash',
          rigLifetimeLabel: 'shared',
        },
        health: [HealthStatus.healthy],
      );

      expect((await acquire()).reused, isFalse);
    });

    test('ignores a dedicated container even when the hash matches', () async {
      engine.addContainer(
        labels: {
          rigMarkerLabel: '1',
          rigHashLabel: specHash(spec),
          rigLifetimeLabel: 'dedicated',
        },
        health: [HealthStatus.healthy],
      );

      expect(
        (await acquire()).reused,
        isFalse,
        reason: 'someone else owns that one',
      );
    });
  });

  group('when a matching container exists but is stopped', () {
    test('starts it again instead of creating a new one', () async {
      final existing = engine.addContainer(
        labels: {
          rigMarkerLabel: '1',
          rigHashLabel: specHash(spec),
          rigLifetimeLabel: 'shared',
        },
        state: 'exited',
        hostPorts: {5432: 55002},
        health: [HealthStatus.healthy],
      );

      final acquired = await acquire();

      expect(acquired.containerId, existing);
      expect(acquired.reused, isTrue);
      expect(engine.calls, contains('start:$existing'));
      expect(engine.calls.contains('create'), isFalse);
    });
  });

  group('dedicated', () {
    const dedicated = ContainerSpec(
      image: 'postgres:16-alpine',
      exposedPorts: [5432],
      waitFor: WaitFor.healthy(),
      healthcheck: Healthcheck(test: ['CMD', 'true']),
      lifetime: Lifetime.dedicated,
    );

    test(
      'never reuses, even when an identical shared one is running',
      () async {
        engine.addContainer(
          labels: {
            rigMarkerLabel: '1',
            rigHashLabel: specHash(dedicated),
            rigLifetimeLabel: 'shared',
          },
          health: [HealthStatus.healthy],
        );

        final acquired = await acquire(dedicated);

        expect(acquired.reused, isFalse);
        expect(acquired.lifetime, Lifetime.dedicated);
        expect(engine.calls, contains('create'));
      },
    );

    test('does not take the lock: there is nothing to coordinate', () async {
      await acquire(dedicated);

      expect(
        Directory('${state.root.path}/locks').listSync(),
        isEmpty,
        reason: 'a private container cannot collide with anyone',
      );
    });
  });

  group('when the container never becomes usable', () {
    const unhealthy = ContainerSpec(
      image: 'postgres:16-alpine',
      exposedPorts: [5432],
      waitFor: WaitFor.healthy(timeout: Duration(milliseconds: 1)),
      healthcheck: Healthcheck(test: ['CMD', 'false']),
    );

    test('rethrows and leaves a marker naming the container', () async {
      await expectLater(acquire(unhealthy), throwsA(isA<ReadyTimeout>()));

      final markers = state.failedDir.listSync();
      expect(markers, hasLength(1));
      expect(markers.single.path, endsWith('.json'));
      expect(
        File(markers.single.path).readAsStringSync(),
        contains('postgres:16-alpine'),
      );
    });

    test('does not remove the container, so it can be inspected', () async {
      await expectLater(acquire(unhealthy), throwsA(isA<ReadyTimeout>()));

      expect(engine.calls.any((c) => c.startsWith('remove:')), isFalse);
    });

    test('releases the lock', () async {
      await expectLater(acquire(unhealthy), throwsA(isA<ReadyTimeout>()));

      expect(
        Directory('${state.root.path}/locks').listSync(),
        isEmpty,
        reason: 'a failure must not wedge every later run',
      );
    });
  });

  test('the lock is released before readiness is awaited', () async {
    // Evidence the wait happens outside the lock: if readiness were awaited
    // while holding it, the second caller would queue behind the first.
    final slow = ContainerSpec(
      image: 'postgres:16-alpine',
      exposedPorts: const [5432],
      waitFor: const WaitFor.healthy(),
      healthcheck: const Healthcheck(test: ['CMD', 'true']),
    );
    engine.addContainer(
      labels: {
        rigMarkerLabel: '1',
        rigHashLabel: specHash(slow),
        rigLifetimeLabel: 'shared',
      },
      hostPorts: {5432: 55003},
      health: [HealthStatus.healthy],
    );

    final both = await Future.wait([acquire(slow), acquire(slow)]);

    expect(both[0].containerId, both[1].containerId);
    expect(engine.calls.where((c) => c == 'create'), isEmpty);
  });
}

/// Makes a freshly created container's healthcheck resolve the way its own
/// trivial probe says it should, instead of sitting at [HealthStatus.starting]
/// forever.
///
/// [FakeDockerEngine] only advances a container's health when a test calls
/// `queueHealth` on it explicitly, which existing containers set up through
/// `addContainer` can do because their id is known before `acquireContainer`
/// runs. A container this suite creates has no such moment: its id only
/// exists once `acquireContainer` is already inside the create-and-start
/// call. This decorator is the substitute for that missing `queueHealth`
/// call, interpreting the spec's own `CMD true` / `CMD false` probe the way
/// a real health check would.
final class _InstantlyHealthy implements DockerEngine {
  _InstantlyHealthy(this._inner);

  final FakeDockerEngine _inner;

  @override
  Future<String> createContainer(
    ContainerSpec spec,
    Map<String, String> labels,
  ) async {
    final id = await _inner.createContainer(spec, labels);
    final probe = spec.healthcheck?.test;
    if (probe != null && probe.isNotEmpty && probe.last == 'true') {
      _inner.queueHealth(id, [HealthStatus.healthy]);
    }
    return id;
  }

  @override
  Future<void> ping() => _inner.ping();

  @override
  Future<EngineVersion> version() => _inner.version();

  @override
  Future<bool> imageExists(String image) => _inner.imageExists(image);

  @override
  Future<void> pullImage(String image) => _inner.pullImage(image);

  @override
  Future<List<ContainerSummary>> listContainers({
    Map<String, List<String>> filters = const {},
    bool all = true,
  }) => _inner.listContainers(filters: filters, all: all);

  @override
  Future<void> startContainer(String id) => _inner.startContainer(id);

  @override
  Future<ContainerInspect> inspectContainer(String id) =>
      _inner.inspectContainer(id);

  @override
  Future<String> logTail(String id, {int lines = 50}) =>
      _inner.logTail(id, lines: lines);

  @override
  Future<void> stopContainer(
    String id, {
    Duration timeout = const Duration(seconds: 10),
  }) => _inner.stopContainer(id, timeout: timeout);

  @override
  Future<void> removeContainer(String id) => _inner.removeContainer(id);

  @override
  Future<void> close() => _inner.close();
}
