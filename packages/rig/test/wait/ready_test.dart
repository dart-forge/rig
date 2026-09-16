import 'dart:io';

import 'package:rig/engine.dart';
import 'package:rig/fake_engine.dart';
import 'package:rig/rig.dart';
import 'package:test/test.dart';

/// A clock that only moves when something sleeps, so timeouts are tested
/// without waiting for them.
final class FakeClock {
  DateTime _now = DateTime.utc(2026, 1, 1);
  Duration slept = Duration.zero;

  DateTime now() => _now;

  Future<void> sleep(Duration d) async {
    _now = _now.add(d);
    slept += d;
  }
}

void main() {
  late FakeDockerEngine engine;
  late FakeClock clock;

  setUp(() {
    engine = FakeDockerEngine();
    clock = FakeClock();
  });

  ReadyTarget targetFor(String id, {Map<int, int> ports = const {}}) =>
      ReadyTarget(
        containerId: id,
        host: '127.0.0.1',
        hostPortOf: (containerPort) => ports[containerPort],
      );

  Future<void> wait(WaitFor strategy, ReadyTarget target) => awaitReady(
    strategy: strategy,
    engine: engine,
    target: target,
    now: clock.now,
    sleep: clock.sleep,
    pollInterval: const Duration(milliseconds: 100),
  );

  group('WaitFor.healthy', () {
    test('returns as soon as Docker reports healthy', () async {
      final id = engine.addContainer(
        labels: const {},
        health: [HealthStatus.healthy],
      );

      await expectLater(
        wait(const WaitFor.healthy(), targetFor(id)),
        completes,
      );
      expect(clock.slept, Duration.zero, reason: 'no need to poll twice');
    });

    test('polls through starting until healthy', () async {
      final id = engine.addContainer(
        labels: const {},
        health: [
          HealthStatus.starting,
          HealthStatus.starting,
          HealthStatus.healthy,
        ],
      );

      await wait(const WaitFor.healthy(), targetFor(id));

      expect(clock.slept, const Duration(milliseconds: 200));
    });

    test('keeps waiting through a transient unhealthy', () async {
      final id = engine.addContainer(
        labels: const {},
        health: [HealthStatus.unhealthy, HealthStatus.healthy],
      );

      await expectLater(
        wait(const WaitFor.healthy(), targetFor(id)),
        completes,
      );
    });

    test('times out with the container logs attached', () async {
      final id = engine.addContainer(
        labels: const {},
        health: [HealthStatus.starting],
      );
      engine.setLogs(id, 'FATAL: password authentication failed');

      await expectLater(
        wait(
          const WaitFor.healthy(timeout: Duration(seconds: 1)),
          targetFor(id),
        ),
        throwsA(
          isA<ReadyTimeout>()
              .having((e) => e.waitingFor, 'waitingFor', contains('healthy'))
              .having(
                (e) => e.logTail,
                'logTail',
                contains('password authentication failed'),
              )
              .having((e) => e.containerId, 'containerId', id),
        ),
      );
    });

    test('fails immediately, not after a timeout, when there is no '
        'healthcheck to read', () async {
      final id = engine.addContainer(labels: const {});

      await expectLater(
        wait(const WaitFor.healthy(), targetFor(id)),
        throwsA(
          isA<NoHealthcheck>().having(
            (e) => e.message,
            'message',
            allOf(contains('healthcheck'), contains('WaitFor.port')),
          ),
        ),
      );
      expect(clock.slept, Duration.zero);
    });

    test('fails fast when the container has exited', () async {
      final id = engine.addContainer(
        labels: const {},
        state: 'exited',
        health: [HealthStatus.starting],
      );
      engine.setLogs(id, 'exec format error');

      await expectLater(
        wait(const WaitFor.healthy(), targetFor(id)),
        throwsA(
          isA<ContainerExited>().having(
            (e) => e.message,
            'message',
            contains('exec format error'),
          ),
        ),
      );
    });
  });

  group('WaitFor.port', () {
    test('returns once something is listening', () async {
      final listener = await ServerSocket.bind('127.0.0.1', 0);
      addTearDown(listener.close);
      final id = engine.addContainer(labels: const {});

      await expectLater(
        wait(
          const WaitFor.port(5432),
          targetFor(id, ports: {5432: listener.port}),
        ),
        completes,
      );
    });

    test('times out when nothing listens', () async {
      // Bind then release to get a port that is almost certainly free.
      final probe = await ServerSocket.bind('127.0.0.1', 0);
      final closedPort = probe.port;
      await probe.close();
      final id = engine.addContainer(labels: const {});

      await expectLater(
        wait(
          const WaitFor.port(5432, timeout: Duration(seconds: 1)),
          targetFor(id, ports: {5432: closedPort}),
        ),
        throwsA(
          isA<ReadyTimeout>().having(
            (e) => e.waitingFor,
            'waitingFor',
            contains('5432'),
          ),
        ),
      );
    });

    test('fails clearly when the port was never published', () async {
      final id = engine.addContainer(labels: const {});

      await expectLater(
        wait(
          const WaitFor.port(9999, timeout: Duration(seconds: 1)),
          targetFor(id),
        ),
        throwsA(
          isA<ReadyTimeout>().having(
            (e) => e.message,
            'message',
            contains('not published'),
          ),
        ),
      );
    });
  });

  group('WaitFor.httpOk', () {
    test('returns once the endpoint answers the expected status', () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      addTearDown(() => server.close(force: true));
      server.listen((r) async {
        r.response.statusCode = r.uri.path == '/healthz' ? 200 : 404;
        await r.response.close();
      });
      final id = engine.addContainer(labels: const {});

      await expectLater(
        wait(
          const WaitFor.httpOk(8080, path: '/healthz'),
          targetFor(id, ports: {8080: server.port}),
        ),
        completes,
      );
    });

    test('keeps waiting while the status is wrong', () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      addTearDown(() => server.close(force: true));
      var hits = 0;
      server.listen((r) async {
        r.response.statusCode = ++hits < 3 ? 503 : 200;
        await r.response.close();
      });
      final id = engine.addContainer(labels: const {});

      await wait(
        const WaitFor.httpOk(8080),
        targetFor(id, ports: {8080: server.port}),
      );

      expect(hits, greaterThanOrEqualTo(3));
    });
  });

  group('WaitFor.all', () {
    test('returns only when every part is satisfied', () async {
      final listener = await ServerSocket.bind('127.0.0.1', 0);
      addTearDown(listener.close);
      final id = engine.addContainer(
        labels: const {},
        health: [HealthStatus.starting, HealthStatus.healthy],
      );

      await expectLater(
        wait(
          const WaitFor.all([WaitFor.healthy(), WaitFor.port(5432)]),
          targetFor(id, ports: {5432: listener.port}),
        ),
        completes,
      );
    });

    test('fails when any part fails', () async {
      final id = engine.addContainer(
        labels: const {},
        health: [HealthStatus.healthy],
      );

      await expectLater(
        wait(
          const WaitFor.all([
            WaitFor.healthy(),
            WaitFor.port(9999, timeout: Duration(seconds: 1)),
          ]),
          targetFor(id),
        ),
        throwsA(isA<ReadyTimeout>()),
      );
    });
  });
}
