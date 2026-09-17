import 'dart:io';

import 'package:rig/module.dart';
import 'package:rig/fake_engine.dart';
import 'package:rig/rig.dart';
import 'package:rig_redis/rig_redis.dart';
import 'package:test/test.dart';

final engine = FakeDockerEngine();
final tmp = Directory.systemTemp.createTempSync('rig_redis_');

void main() {
  overrideEngine(engine);
  tearDownAll(() => tmp.deleteSync(recursive: true));

  group('a shared Redis', () {
    final redis = useRedis(stateDir: StateDir(tmp));

    test('is reachable by the time a test body runs', () {
      expect(redis.port, greaterThan(1024));
      expect(redis.url, startsWith('redis://127.0.0.1:'));
      expect(redis.database, 0);
    });
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

    test('share the same container', () {
      expect(first.container.containerId, second.container.containerId);
    });
  });
}
