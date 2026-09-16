import 'package:rig/engine.dart';
import 'package:rig/fake_engine.dart';
import 'package:rig/rig.dart';
import 'package:test/test.dart';

void main() {
  late FakeDockerEngine engine;

  setUp(() => engine = FakeDockerEngine());

  AcquiredContainer acquired({
    String id = 'cid',
    Map<int, int> ports = const {5432: 54321},
    Lifetime lifetime = Lifetime.shared,
    bool reused = false,
  }) => AcquiredContainer(
    containerId: id,
    host: '127.0.0.1',
    hostPorts: ports,
    lifetime: lifetime,
    reused: reused,
    hash: 'h',
  );

  test('exposes the host and the mapped port', () {
    final lease = ContainerLease.of(engine, acquired());

    expect(lease.host, '127.0.0.1');
    expect(lease.port(5432), 54321);
    expect(lease.endpoint(5432), '127.0.0.1:54321');
  });

  test('names the ports that are published when asked for another', () {
    final lease = ContainerLease.of(
      engine,
      acquired(ports: {5432: 1, 8080: 2}),
    );

    expect(
      () => lease.port(9999),
      throwsA(
        isA<PortNotPublished>()
            .having((e) => e.message, 'message', contains('9999'))
            .having((e) => e.message, 'message', contains('5432'))
            .having((e) => e.message, 'message', contains('8080')),
      ),
    );
  });

  test(
    'reading before the container is acquired says where to move the read',
    () {
      final lease = ContainerLease.pending(() => engine);

      expect(() => lease.host, throwsA(isA<LeaseNotBound>()));
      expect(() => lease.port(5432), throwsA(isA<LeaseNotBound>()));
      expect(() => lease.containerId, throwsA(isA<LeaseNotBound>()));
    },
  );

  test('binding makes it readable', () {
    final lease = ContainerLease.pending(() => engine)..bind(acquired());

    expect(lease.port(5432), 54321);
  });

  group('release', () {
    test('leaves a shared container running', () async {
      final lease = ContainerLease.of(engine, acquired());

      await lease.release();

      expect(
        engine.calls,
        isEmpty,
        reason: 'the next run should not pay for startup again',
      );
    });

    test('stops and removes a dedicated container', () async {
      final id = engine.addContainer(labels: const {});
      final lease = ContainerLease.of(
        engine,
        acquired(id: id, lifetime: Lifetime.dedicated),
      );

      await lease.release();

      expect(engine.calls, ['stop:$id', 'remove:$id']);
    });

    test('is safe to call twice', () async {
      final id = engine.addContainer(labels: const {});
      final lease = ContainerLease.of(
        engine,
        acquired(id: id, lifetime: Lifetime.dedicated),
      );

      await lease.release();
      await lease.release();

      expect(engine.calls, ['stop:$id', 'remove:$id']);
    });

    test('reports the same failure again on retry, rather than a silent '
        'no-op that leaves the container stopped but never removed', () async {
      final id = engine.addContainer(labels: const {});
      final lease = ContainerLease.of(
        engine,
        acquired(id: id, lifetime: Lifetime.dedicated),
      );
      engine.removeError = StateError('boom');

      await expectLater(lease.release(), throwsA(isA<StateError>()));
      await expectLater(
        lease.release(),
        throwsA(isA<StateError>()),
        reason:
            'a caller retrying after a real failure must be told again, '
            'not handed a false success',
      );

      expect(engine.calls, [
        'stop:$id',
        'remove:$id',
      ], reason: 'one attempt, reported twice — not one attempt per call');
    });

    test('does nothing when the container was never acquired', () async {
      await expectLater(
        ContainerLease.pending(() => engine).release(),
        completes,
      );
      expect(engine.calls, isEmpty);
    });
  });

  test('log tail comes from the engine', () async {
    final id = engine.addContainer(labels: const {});
    engine.setLogs(id, 'some output');
    final lease = ContainerLease.of(engine, acquired(id: id));

    expect(await lease.logTail(), 'some output');
  });

  test('reports whether the container was reused', () {
    expect(ContainerLease.of(engine, acquired(reused: true)).reused, isTrue);
    expect(ContainerLease.of(engine, acquired(reused: false)).reused, isFalse);
  });
}
