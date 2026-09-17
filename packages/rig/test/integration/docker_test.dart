@Tags(['integration'])
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rig/engine.dart';
import 'package:rig/rig.dart';
import 'package:test/test.dart';

/// Every container this suite makes carries this, so the teardown can find
/// them all even if a test fails halfway.
const _ownLabel = 'dev.dart-forge.rig.test.run';

void main() {
  late DockerEngine engine;
  late Directory tmp;
  late StateDir state;
  late String runId;

  setUpAll(() async {
    engine = await connectToDocker();
    runId = DateTime.now().microsecondsSinceEpoch.toString();
  });

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('rig_it_');
    state = StateDir(tmp)..ensure();
  });

  tearDown(() async {
    final mine = await engine.listContainers(
      filters: {
        'label': ['$_ownLabel=$runId'],
      },
    );
    for (final c in mine) {
      await engine.removeContainer(c.id);
    }
    tmp.deleteSync(recursive: true);
  });

  tearDownAll(() => engine.close());

  ContainerSpec alpine({
    Lifetime lifetime = Lifetime.shared,
    String marker = 'a',
    ContainerNetwork? network,
  }) => ContainerSpec(
    image: 'alpine:3.20',
    // Keep it alive: alpine's default command exits at once.
    command: const ['sleep', '300'],
    env: {'RIG_TEST_MARKER': marker},
    labels: {_ownLabel: runId},
    healthcheck: const Healthcheck(
      test: ['CMD-SHELL', 'true'],
      interval: Duration(milliseconds: 250),
      retries: 20,
    ),
    waitFor: const WaitFor.healthy(timeout: Duration(seconds: 60)),
    lifetime: lifetime,
    network: network,
  );

  Future<AcquiredContainer> acquire(ContainerSpec spec) => acquireContainer(
    spec: spec,
    engine: engine,
    stateDir: state,
    project: 'rig_integration',
  );

  test(
    'injects a healthcheck into an image that has none, and waits on it',
    () async {
      // alpine:3.20 ships no HEALTHCHECK. If health never leaves `none`, the
      // whole readiness strategy this design rests on does not work.
      final acquired = await acquire(alpine(marker: 'inject'));

      final inspected = await engine.inspectContainer(acquired.containerId);
      expect(inspected.health, HealthStatus.healthy);
      expect(inspected.running, isTrue);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('publishes a port Docker chose, not one rig asked for', () async {
    final spec = ContainerSpec(
      image: 'alpine:3.20',
      command: const ['sleep', '300'],
      exposedPorts: const [5432],
      labels: {_ownLabel: runId},
      healthcheck: const Healthcheck(
        test: ['CMD-SHELL', 'true'],
        interval: Duration(milliseconds: 250),
        retries: 20,
      ),
      waitFor: const WaitFor.healthy(),
    );

    final acquired = await acquire(spec);

    expect(acquired.hostPorts[5432], isNotNull);
    expect(
      acquired.hostPorts[5432],
      isNot(5432),
      reason: 'an ephemeral port is the point',
    );
    expect(acquired.hostPorts[5432], greaterThan(1024));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test(
    'a second acquire of the same spec reuses the first container',
    () async {
      final spec = alpine(marker: 'reuse');

      final first = await acquire(spec);
      final second = await acquire(spec);

      expect(second.containerId, first.containerId);
      expect(first.reused, isFalse);
      expect(second.reused, isTrue);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('a different spec gets a different container', () async {
    final a = await acquire(alpine(marker: 'one'));
    final b = await acquire(alpine(marker: 'two'));

    expect(b.containerId, isNot(a.containerId));
  }, timeout: const Timeout(Duration(minutes: 3)));

  group('network', () {
    Future<bool> removeNetworkByName(String dockerName) async {
      final found = await engine.listNetworks(
        filters: {
          'label': [rigMarkerLabel],
        },
      );
      final match = found.where((n) => n.name == dockerName);
      if (match.isEmpty) return true; // never created, or already gone
      return engine.removeNetwork(match.first.id);
    }

    test('two containers on a network resolve each other by alias, and the '
        'same two containers without one cannot — proving the network, not '
        'plain reachability, did it', () async {
      // A network name unique to this run: two CI jobs on the same daemon
      // at once must not race over the same `rig-<name>` network. This is
      // the raw name a spec gives [ContainerNetwork] — rig adds its own
      // `rig-` prefix, so the actual Docker network is `rig-it-network-<id>`.
      final networkName = 'it-network-$runId';

      // --- positive: on a shared network, alias resolves ---
      final peer = await acquire(
        alpine(
          marker: 'net-peer',
          lifetime: Lifetime.dedicated,
          network: ContainerNetwork(networkName, alias: 'peer'),
        ),
      );
      final caller = await acquire(
        alpine(
          marker: 'net-caller',
          lifetime: Lifetime.dedicated,
          network: ContainerNetwork(networkName),
        ),
      );
      final peerLease = ContainerLease.of(engine, peer);
      final callerLease = ContainerLease.of(engine, caller);

      final withNetwork = await callerLease.exec([
        'getent',
        'hosts',
        'peer',
      ], expectSuccess: false);

      // Release before the negative control: the point is that the two
      // containers below cannot resolve the alias, not that they cannot
      // resolve it *while it is being served by containers of the same
      // name and marker*.
      await peerLease.release();
      await callerLease.release();
      expect(
        await removeNetworkByName(ContainerNetwork(networkName).dockerName),
        isTrue,
        reason:
            'both endpoints were just released, so nothing should still '
            'be attached',
      );

      // --- negative control: the same two containers, no network ---
      final peerAgain = await acquire(
        alpine(marker: 'net-peer', lifetime: Lifetime.dedicated),
      );
      final callerAgain = await acquire(
        alpine(marker: 'net-caller', lifetime: Lifetime.dedicated),
      );
      final callerAgainLease = ContainerLease.of(engine, callerAgain);

      final withoutNetwork = await callerAgainLease.exec([
        'getent',
        'hosts',
        'peer',
      ], expectSuccess: false);

      await ContainerLease.of(engine, peerAgain).release();
      await callerAgainLease.release();

      // Both outcomes go in the report as required by the brief: this is
      // the only evidence in the repository that the feature works at
      // all, and a passing positive case alone cannot distinguish "the
      // network did it" from "they could always reach each other".
      // ignore: avoid_print
      print(
        'with network:    exit=${withNetwork.exitCode} '
        'output=${withNetwork.output.trim()}',
      );
      // ignore: avoid_print
      print(
        'without network: exit=${withoutNetwork.exitCode} '
        'output=${withoutNetwork.output.trim()}',
      );

      expect(withNetwork.exitCode, 0);
      expect(withNetwork.output, contains('peer'));
      expect(withoutNetwork.exitCode, isNot(0));
      expect(withoutNetwork.output.trim(), isEmpty);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  test('releasing a shared lease leaves the container running', () async {
    final acquired = await acquire(alpine(marker: 'keep'));
    final lease = ContainerLease.of(engine, acquired);

    await lease.release();

    expect(
      (await engine.inspectContainer(acquired.containerId)).running,
      isTrue,
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('releasing a dedicated lease removes the container', () async {
    final acquired = await acquire(
      alpine(lifetime: Lifetime.dedicated, marker: 'own'),
    );
    final lease = ContainerLease.of(engine, acquired);

    await lease.release();

    await expectLater(
      engine.inspectContainer(acquired.containerId),
      throwsA(isA<EngineError>().having((e) => e.statusCode, 'status', 404)),
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  group('ContainerLease.exec', () {
    test('runs a command and returns its output', () async {
      final acquired = await acquire(alpine(marker: 'exec-ok'));
      final lease = ContainerLease.of(engine, acquired);

      final result = await lease.exec(['sh', '-c', 'echo hello']);

      expect(result.exitCode, 0);
      expect(result.output.trim(), 'hello');
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('a non-zero exit throws ExecFailed with the exit code in the '
        'message', () async {
      final acquired = await acquire(alpine(marker: 'exec-fail'));
      final lease = ContainerLease.of(engine, acquired);

      await expectLater(
        lease.exec(['sh', '-c', 'exit 3']),
        throwsA(
          isA<ExecFailed>()
              .having((e) => e.exitCode, 'exitCode', 3)
              .having((e) => e.message, 'message', contains('3')),
        ),
      );
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  test(
    'waits on a log message from a container that never opens a port',
    () async {
      // No exposedPorts, no healthcheck: a port wait or a health wait could
      // never succeed on this container, so completing here proves the log
      // wait itself did the work.
      final spec = ContainerSpec(
        image: 'alpine:3.20',
        command: const ['sh', '-c', 'echo ready; sleep 300'],
        labels: {_ownLabel: runId},
        waitFor: const WaitFor.logMessage(
          'ready',
          timeout: Duration(seconds: 30),
        ),
      );

      final acquired = await acquire(spec);

      expect(
        (await engine.inspectContainer(acquired.containerId)).running,
        isTrue,
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'a container that never becomes healthy fails with its own logs',
    () async {
      final spec = ContainerSpec(
        image: 'alpine:3.20',
        command: const ['sh', '-c', 'echo "this is the log line"; sleep 300'],
        labels: {_ownLabel: runId},
        healthcheck: const Healthcheck(
          test: ['CMD-SHELL', 'false'],
          interval: Duration(milliseconds: 250),
          retries: 2,
        ),
        waitFor: const WaitFor.healthy(timeout: Duration(seconds: 5)),
      );

      await expectLater(
        acquire(spec),
        throwsA(
          isA<ReadyTimeout>().having(
            (e) => e.logTail,
            'logTail',
            contains('this is the log line'),
          ),
        ),
      );

      // It has to still be there. A container nobody can inspect is no use.
      final marker = state.failedDir.listSync();
      expect(marker, hasLength(1));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  group('useContainer', () {
    // useContainer registers its own setUpAll/tearDownAll when it is called,
    // so the spec (and its label) has to be built here, at declaration
    // time, rather than inside a test or the outer setUpAll above.
    final marker = 'usecontainer-${DateTime.now().microsecondsSinceEpoch}';
    final leased = useContainer(
      ContainerSpec(
        image: 'redis:7-alpine',
        exposedPorts: const [6379],
        labels: {_ownLabel: marker},
        healthcheck: const Healthcheck(
          test: ['CMD-SHELL', 'redis-cli ping'],
          interval: Duration(milliseconds: 250),
          retries: 40,
        ),
        waitFor: const WaitFor.healthy(timeout: Duration(seconds: 60)),
        lifetime: Lifetime.dedicated,
      ),
      project: 'rig_integration_use_container',
    );

    test('is the only call a consumer needs: it hands back a port a test '
        'can actually connect to', () async {
      final socket = await Socket.connect(
        leased.host,
        leased.port(6379),
        timeout: const Duration(seconds: 5),
      );
      addTearDown(socket.destroy);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  group('postgres', () {
    ContainerSpec postgres() => ContainerSpec(
      image: 'postgres:16-alpine',
      env: const {
        'POSTGRES_USER': 'test',
        'POSTGRES_PASSWORD': 'test',
        'POSTGRES_DB': 'test_db',
      },
      exposedPorts: const [5432],
      tmpfs: const {'/var/lib/postgresql/data'},
      labels: {_ownLabel: runId},
      healthcheck: const Healthcheck(
        test: ['CMD-SHELL', 'pg_isready -h 127.0.0.1 -U test'],
        interval: Duration(milliseconds: 250),
        timeout: Duration(seconds: 3),
        retries: 60,
      ),
      waitFor: const WaitFor.healthy(timeout: Duration(seconds: 120)),
    );

    test(
      'becomes healthy and accepts a TCP connection on the mapped port',
      () async {
        // pg_isready -h 127.0.0.1 is the load-bearing detail: during initdb the
        // official entrypoint runs a temporary server on the unix socket only,
        // so a TCP probe cannot be fooled into reporting ready too early.
        final acquired = await acquire(postgres());
        final port = acquired.hostPorts[5432]!;

        final socket = await Socket.connect(
          '127.0.0.1',
          port,
          timeout: const Duration(seconds: 5),
        );
        addTearDown(socket.destroy);

        expect(
          (await engine.inspectContainer(acquired.containerId)).health,
          HealthStatus.healthy,
        );
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    test('the image ships pg_isready', () async {
      // If it did not, the readiness strategy for the Postgres module would
      // have to change before that module is written.
      final acquired = await acquire(postgres());

      expect(
        (await engine.inspectContainer(acquired.containerId)).health,
        HealthStatus.healthy,
        reason: 'a missing pg_isready would leave health at starting',
      );
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('runs a command inside the container and reads its output', () async {
      // The Postgres module creates its per-suite database this way, so the
      // path matters more than the one command being run here.
      final acquired = await acquire(postgres());

      final result = await engine.exec(acquired.containerId, [
        'psql',
        '-U',
        'test',
        '-d',
        'test_db',
        '-tAc',
        "SELECT 'exec ok'",
      ]);

      expect(result.exitCode, 0);
      expect(result.output.trim(), 'exec ok');
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('build', () {
    late Directory contextDir;

    setUp(() {
      contextDir = Directory(p.join(tmp.path, 'ctx'))..createSync();
    });

    /// Best-effort: it is test hygiene, not the feature under test, so a
    /// failure here must not fail the test that already made its point.
    ///
    /// Goes through the engine rather than the Docker CLI, because rig claims
    /// to need no CLI and its own suite should not quietly depend on one.
    Future<void> removeImageTag(String tag) async {
      try {
        await (await currentEngine()).removeImage(tag);
      } on Object {
        // Nothing to do about it here.
      }
    }

    ContainerSpec builtAlpine(String tag) => ContainerSpec(
      image: tag,
      command: const ['sleep', '300'],
      labels: {_ownLabel: runId},
      healthcheck: const Healthcheck(
        test: ['CMD-SHELL', 'true'],
        interval: Duration(milliseconds: 250),
        retries: 20,
      ),
      waitFor: const WaitFor.healthy(timeout: Duration(seconds: 60)),
      build: ContainerBuild(context: contextDir.path),
    );

    test(
      'builds an image from a Dockerfile and runs a container from it',
      () async {
        final tag = 'rig-build-test:$runId';
        addTearDown(() => removeImageTag(tag));
        File(p.join(contextDir.path, 'Dockerfile')).writeAsStringSync('''
FROM alpine:3.20
RUN echo "built by rig $runId" > /etc/rig-probe
''');

        final acquired = await acquire(builtAlpine(tag));
        final lease = ContainerLease.of(engine, acquired);

        final probe = await lease.exec(['cat', '/etc/rig-probe']);

        expect(
          probe.output,
          contains('built by rig $runId'),
          reason:
              'proves the container is running the image rig just built, '
              'not some pre-existing image under the same tag',
        );
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test('a Dockerfile that fails inside RUN throws ImageBuildFailed carrying '
        'the build output, even though POST /build answered 200', () async {
      final tag = 'rig-build-fail-test:$runId';
      addTearDown(() => removeImageTag(tag));
      File(p.join(contextDir.path, 'Dockerfile')).writeAsStringSync('''
FROM alpine:3.20
RUN echo "about to fail, marker $runId"
RUN exit 1
''');

      Object? caught;
      try {
        await acquire(builtAlpine(tag));
      } catch (error) {
        caught = error;
      }

      expect(caught, isA<ImageBuildFailed>());
      // Printed for the record: this is the only evidence in the
      // repository that a build failing inside the response stream (not
      // the HTTP status) surfaces as ImageBuildFailed, with the build
      // output attached.
      // ignore: avoid_print
      print(
        'ImageBuildFailed message:\n${(caught as ImageBuildFailed).message}',
      );

      expect(
        caught.message,
        contains('about to fail, marker $runId'),
        reason:
            'the output leading up to the failure must be in the '
            'message, or there is no way to tell which RUN step broke',
      );
      expect(caught.message, contains('exit 1'));
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('the executable bit on a context file survives the build: a RUN of '
        'it only succeeds if the mode came through', () async {
      final tag = 'rig-build-mode-test:$runId';
      addTearDown(() => removeImageTag(tag));
      final script = File(p.join(contextDir.path, 'probe.sh'))
        ..writeAsStringSync('#!/bin/sh\necho "script ran, marker $runId"\n');
      await Process.run('chmod', ['755', script.path]);
      File(p.join(contextDir.path, 'Dockerfile')).writeAsStringSync('''
FROM alpine:3.20
COPY probe.sh /probe.sh
RUN /probe.sh
''');

      // If the executable bit were lost, RUN /probe.sh would fail with
      // "Permission denied" and this would throw ImageBuildFailed instead
      // of returning — a passing acquire is the proof the mode survived.
      final acquired = await acquire(builtAlpine(tag));

      expect(
        (await engine.inspectContainer(acquired.containerId)).running,
        isTrue,
      );
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
