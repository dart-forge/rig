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

  // Nothing in these cases needs real time to pass: the fake's health
  // transition is driven by the number of polls, not by the clock.
  Future<AcquiredContainer> acquire([ContainerSpec s = spec]) =>
      acquireContainer(
        spec: s,
        engine: engine,
        stateDir: state,
        project: 'aim_postgres',
        sleep: (_) async {},
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

    setUp(() => engine.healthAfterCreate = const [HealthStatus.starting]);

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

  test('two concurrent acquires of one spec share a container', () async {
    engine.addContainer(
      labels: {
        rigMarkerLabel: '1',
        rigHashLabel: specHash(spec),
        rigLifetimeLabel: 'shared',
      },
      hostPorts: {5432: 55003},
      health: [HealthStatus.healthy],
    );

    final both = await Future.wait([acquire(), acquire()]);

    expect(both[0].containerId, both[1].containerId);
    expect(engine.calls.where((c) => c == 'create'), isEmpty);
  });

  test('the lock is not held while readiness is awaited', () async {
    // Observed directly rather than inferred from timing. The only sleeping
    // this call does is inside the readiness poll — the lock's own retry loop
    // never sleeps when the lock is free — so if the lock file exists at that
    // moment, readiness is being awaited while holding it, which would stall
    // every other suite for the length of the wait.
    var lockHeldDuringWait = false;

    await acquireContainer(
      spec: spec,
      engine: engine,
      stateDir: state,
      project: 'aim_postgres',
      sleep: (_) async {
        if (Link(state.lockPath(specHash(spec))).existsSync()) {
          lockHeldDuringWait = true;
        }
      },
    );

    expect(
      lockHeldDuringWait,
      isFalse,
      reason: 'the lock must cover create and start only',
    );
  });
}
