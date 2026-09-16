@Tags(['integration'])
library;

import 'dart:io';

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
  });
}
