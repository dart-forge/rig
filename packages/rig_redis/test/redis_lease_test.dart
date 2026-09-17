import 'package:rig/module.dart';
import 'package:rig/fake_engine.dart';
import 'package:rig/rig.dart';
import 'package:rig_redis/rig_redis.dart';
import 'package:test/test.dart';

void main() {
  late FakeDockerEngine engine;

  setUp(() => engine = FakeDockerEngine());

  ContainerLease leaseFor({Map<int, int> ports = const {6379: 54321}}) =>
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

  test('builds a url with no password', () {
    final redis = RedisLease(container: leaseFor())..bindDatabase(0);

    expect(redis.url, 'redis://127.0.0.1:54321/0');
  });

  test('builds a url with a password', () {
    final redis = RedisLease(container: leaseFor(), password: 'hunter2')
      ..bindDatabase(0);

    expect(redis.url, 'redis://:hunter2@127.0.0.1:54321/0');
  });

  test('escapes a password that would otherwise break the url', () {
    final redis = RedisLease(container: leaseFor(), password: 'p@ss:word/x')
      ..bindDatabase(0);

    expect(Uri.parse(redis.url).userInfo, ':p%40ss%3Aword%2Fx');
  });

  test('exposes the parts as well as the url', () {
    final redis = RedisLease(
      container: leaseFor(ports: {6379: 55000}),
      password: 'hunter2',
    )..bindDatabase(0);

    expect(redis.host, '127.0.0.1');
    expect(redis.port, 55000);
    expect(redis.password, 'hunter2');
    expect(redis.database, 0);
  });

  test('hands through to the container it wraps', () {
    final lease = leaseFor();
    final redis = RedisLease(container: lease)..bindDatabase(0);

    expect(redis.container, same(lease));
  });

  test('database throws LeaseNotBound before setUpAll has run', () {
    final redis = RedisLease(container: leaseFor());

    expect(() => redis.database, throwsA(isA<LeaseNotBound>()));
  });

  test('url throws LeaseNotBound before setUpAll has run too', () {
    // url reads host/port/database, all of which need binding first.
    final redis = RedisLease(container: leaseFor());

    expect(() => redis.url, throwsA(isA<LeaseNotBound>()));
  });

  test('database reads back what bindDatabase set', () {
    final redis = RedisLease(container: leaseFor());

    redis.bindDatabase(0);

    expect(redis.database, 0);
  });
}
