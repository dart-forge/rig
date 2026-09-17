import 'dart:io';

import 'package:rig/module.dart';
import 'package:rig/fake_engine.dart';
import 'package:rig/rig.dart';
import 'package:rig_redis/rig_redis.dart';
import 'package:test/test.dart';

final engine = FakeDockerEngine()
  ..onExec = (_) => const ExecResult(exitCode: 0, output: 'OK');
final tmp = Directory.systemTemp.createTempSync('rig_redis_');

void main() {
  overrideEngine(engine);
  tearDownAll(() => tmp.deleteSync(recursive: true));

  group('a shared Redis', () {
    final redis = useRedis(stateDir: StateDir(tmp));

    test(
      'is reachable by the time a test body runs, at an index of its own',
      () {
        expect(redis.port, greaterThan(1024));
        expect(redis.url, startsWith('redis://127.0.0.1:'));
        expect(redis.database, isNot(0));
        expect(redis.url, endsWith('/${redis.database}'));
      },
    );
  });

  group('a password gets into the url', () {
    final redis = useRedis(
      password: 'hunter2',
      stateDir: StateDir(tmp),
      // A different config than the group above, so this does not just
      // reuse its container and skip exercising its own spec.
      databases: 32,
    );

    test('as userinfo', () {
      expect(redis.url, startsWith('redis://:hunter2@'));
    });
  });

  group('two suites on one container', () {
    final first = useRedis(stateDir: StateDir(tmp));
    final second = useRedis(stateDir: StateDir(tmp));

    test('share the same container but not the same index', () {
      expect(first.container.containerId, second.container.containerId);
      expect(first.database, isNot(second.database));
      expect(first.database, isNot(0));
      expect(second.database, isNot(0));
    });
  });

  group('isolation: none', () {
    final first = useRedis(
      isolation: RedisIsolation.none,
      stateDir: StateDir(tmp),
      // A config nothing else in this file uses, so both suites below are
      // guaranteed to share one container with each other and nothing else.
      databases: 12,
    );
    final second = useRedis(
      isolation: RedisIsolation.none,
      stateDir: StateDir(tmp),
      databases: 12,
    );

    test('both suites see index 0, the point of turning isolation off', () {
      expect(first.container.containerId, second.container.containerId);
      expect(first.database, 0);
      expect(second.database, 0);
    });
  });
}
