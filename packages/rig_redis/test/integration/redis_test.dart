@Tags(['integration'])
library;

import 'dart:io';

import 'package:rig/rig.dart';
import 'package:rig_redis/rig_redis.dart';
import 'package:test/test.dart';

void main() {
  group('a shared Redis', () {
    final redis = useRedis();

    test('SET and GET round-trip through redis-cli', () async {
      final set = await redis.container.exec([
        'redis-cli',
        'SET',
        'greeting',
        'hello',
      ]);
      expect(set.output.trim(), 'OK');

      final get = await redis.container.exec(['redis-cli', 'GET', 'greeting']);
      expect(get.output.trim(), 'hello');
    });

    test('a real Redis answers on the mapped host port', () async {
      // redis.host/redis.port are the module's whole product; the assertion
      // above runs inside the container instead of through them.
      final socket = await Socket.connect(redis.host, redis.port);
      addTearDown(socket.close);
      expect(socket.remotePort, redis.port);
    });
  });

  group('--databases is really in effect', () {
    final redis = useRedis(databases: 37, lifetime: Lifetime.dedicated);

    test('CONFIG GET databases reports what was asked for', () async {
      final result = await redis.container.exec([
        'redis-cli',
        'CONFIG',
        'GET',
        'databases',
      ]);
      // CONFIG GET replies with the key on one line and the value on the
      // next.
      expect(result.output.trim().split('\n').last.trim(), '37');
    });
  });

  group('a password is genuinely enforced', () {
    final redis = useRedis(password: 'hunter2', lifetime: Lifetime.dedicated);

    test('the correct password connects', () async {
      final result = await redis.container.exec([
        'redis-cli',
        '-a',
        'hunter2',
        // Suppresses the "Using a password with -a" warning, which redis-cli
        // writes to stderr — Docker's exec API has no separate stderr for
        // rig to filter, so without this it would land mixed into the same
        // output a caller reads. Confirmed empirically: the warning appears
        // ahead of PONG in ExecResult.output without this flag, and is gone
        // with it.
        '--no-auth-warning',
        'ping',
      ]);
      expect(result.output.trim(), 'PONG');
    });

    test('a wrong password is refused', () async {
      // One half alone cannot tell "the password took effect" from "there
      // was no password at all" — this pairs with the test above.
      //
      // redis-cli exits 0 here even though authentication failed (confirmed
      // empirically), so the check is on the output text, not the exit
      // code — the same reason the injected healthcheck greps instead of
      // trusting `redis-cli ping`'s own exit status.
      final result = await redis.container.exec([
        'redis-cli',
        '-a',
        'wrong-password',
        '--no-auth-warning',
        'ping',
      ]);
      expect(result.output, contains('NOAUTH'));
      expect(result.output, isNot(contains('PONG')));
    });
  });

  group('two suites asking for the same configuration', () {
    final first = useRedis();
    final second = useRedis();

    test('share one container', () {
      expect(
        first.container.containerId,
        second.container.containerId,
        reason: 'the same request should share one container',
      );
    });
  });
}
