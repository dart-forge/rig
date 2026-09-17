import 'package:rig/engine.dart';
import 'package:rig/rig.dart';
import 'package:rig_redis/rig_redis.dart';
import 'package:test/test.dart';

void main() {
  test('runs the version asked for', () {
    expect(redisSpec(version: '6-alpine').image, 'redis:6-alpine');
    expect(redisSpec().image, 'redis:7-alpine');
  });

  test('publishes the Redis port', () {
    expect(redisSpec().exposedPorts, [6379]);
  });

  test('is shared by default and can be asked for a private one', () {
    expect(redisSpec().lifetime, Lifetime.shared);
    expect(
      redisSpec(lifetime: Lifetime.dedicated).lifetime,
      Lifetime.dedicated,
    );
  });

  test('injects a healthcheck the official image does not ship', () {
    final spec = redisSpec();

    expect(spec.healthcheck, isNotNull);
    // redis-cli ping can exit 0 even when it failed (e.g. NOAUTH), so the
    // check has to look at the output rather than trust the exit code.
    expect(spec.healthcheck!.test, [
      'CMD-SHELL',
      'redis-cli ping | grep -q PONG',
    ]);
    expect(spec.waitFor, isA<HealthyWait>());
  });

  test('authenticates its own healthcheck probe when there is a password', () {
    // Without this, a password-protected server never passes its own
    // healthcheck: `redis-cli ping` unauthenticated prints NOAUTH forever,
    // so `waitFor: WaitFor.healthy()` would time out on every container this
    // module starts with a password. Confirmed against a real daemon.
    final spec = redisSpec(password: 'hunter2');

    expect(spec.healthcheck!.test, [
      'CMD-SHELL',
      "redis-cli -a 'hunter2' --no-auth-warning ping | grep -q PONG",
    ]);
  });

  test('passes no --requirepass when no password is given', () {
    final command = redisSpec().command;

    expect(command, isNot(contains('--requirepass')));
  });

  test('a password becomes --requirepass', () {
    final command = redisSpec(password: 'hunter2').command;

    expect(command.first, 'redis-server');
    expect(command, containsAllInOrder(['--requirepass', 'hunter2']));
  });

  test('databases becomes --databases', () {
    final command = redisSpec(databases: 32).command;

    expect(command.first, 'redis-server');
    expect(command, containsAllInOrder(['--databases', '32']));
  });

  test('defaults to 64 databases, not the image default of 16', () {
    expect(redisSpec().command, containsAllInOrder(['--databases', '64']));
  });

  test('redis-server leads the argument list exactly once, either way', () {
    // Both password and databases are always present in A (databases
    // defaults to 64, never omitted), so redis-server must lead the combined
    // list rather than being repeated for each flag.
    final command = redisSpec(password: 'hunter2', databases: 32).command;

    expect(command.where((a) => a == 'redis-server'), hasLength(1));
    expect(command.first, 'redis-server');
    expect(
      command,
      containsAllInOrder(['--requirepass', 'hunter2', '--databases', '32']),
    );
  });

  test('two specs asking for the same thing are interchangeable', () {
    expect(
      specHash(redisSpec(password: 'a')),
      specHash(redisSpec(password: 'a')),
    );
    expect(
      specHash(redisSpec(password: 'a')),
      isNot(specHash(redisSpec(password: 'b'))),
    );
    expect(specHash(redisSpec()), isNot(specHash(redisSpec(databases: 32))));
  });
}
