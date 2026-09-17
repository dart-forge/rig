import 'package:rig/engine.dart';
import 'package:rig/fake_engine.dart';
import 'package:rig/rig.dart';
import 'package:rig_postgres/rig_postgres.dart';
import 'package:test/test.dart';

void main() {
  late FakeDockerEngine engine;

  setUp(() => engine = FakeDockerEngine());

  ContainerLease leaseFor({Map<int, int> ports = const {5432: 54321}}) =>
      // ignore: invalid_use_of_internal_member
      ContainerLease.of(
        engine,
        AcquiredContainer(
          containerId: 'cid',
          host: '127.0.0.1',
          hostPorts: ports,
          lifetime: Lifetime.shared,
          reused: false,
          hash: 'h',
        ),
      );

  test('builds a url a Postgres client will accept', () {
    final pg = PostgresLease(
      container: leaseFor(),
      user: 'alice',
      password: 'hunter2',
      database: 'shop',
    );

    expect(pg.url, 'postgresql://alice:hunter2@127.0.0.1:54321/shop');
  });

  test('exposes the parts as well as the url', () {
    final pg = PostgresLease(
      container: leaseFor(ports: {5432: 55000}),
      user: 'alice',
      password: 'hunter2',
      database: 'shop',
    );

    expect(pg.host, '127.0.0.1');
    expect(pg.port, 55000);
    expect(pg.user, 'alice');
    expect(pg.password, 'hunter2');
    expect(pg.database, 'shop');
  });

  test('escapes credentials that would otherwise break the url', () {
    final pg = PostgresLease(
      container: leaseFor(),
      user: 'al ice',
      password: 'p@ss:word/x',
      database: 'shop',
    );

    // A caller should be able to hand this to a client without thinking.
    expect(Uri.parse(pg.url).userInfo, 'al%20ice:p%40ss%3Aword%2Fx');
    expect(Uri.parse(pg.url).port, 54321);
  });

  test('hands through to the container it wraps', () {
    final lease = leaseFor();
    final pg = PostgresLease(
      container: lease,
      user: 'test',
      password: 'test',
      database: 'test_db',
    );

    expect(pg.container, same(lease));
  });
}
