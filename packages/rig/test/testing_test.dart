import 'dart:io';

import 'package:rig/engine.dart';
import 'package:rig/fake_engine.dart';
import 'package:rig/rig.dart';
import 'package:test/test.dart';

/// useContainer registers its hooks when it is called, so the fake engine has
/// to be installed here, at declaration time, before any setUpAll runs.
final engine = FakeDockerEngine();
final tmp = Directory.systemTemp.createTempSync('rig_use_');

void main() {
  overrideEngine(engine);
  tearDownAll(() => tmp.deleteSync(recursive: true));

  const spec = ContainerSpec(
    image: 'redis:7-alpine',
    exposedPorts: [6379],
    waitFor: WaitFor.healthy(),
    healthcheck: Healthcheck(test: ['CMD', 'true']),
  );

  group('a shared container', () {
    final cache = useContainer(spec, project: 'demo', stateDir: StateDir(tmp));

    test('is running and readable by the time a test body runs', () {
      expect(cache.containerId, isNotEmpty);
      expect(cache.port(6379), greaterThan(1024));
      expect(cache.host, '127.0.0.1');
    });

    test('is the same container for every test in the suite', () {
      // setUpAll runs once per group, so both tests see one container.
      expect(engine.calls.where((c) => c == 'create'), hasLength(1));
    });
  });

  group('a second suite with the same spec', () {
    final cache = useContainer(spec, project: 'demo', stateDir: StateDir(tmp));

    test('reuses the container the first group left running', () {
      expect(cache.reused, isTrue);
      expect(engine.calls.where((c) => c == 'create'), hasLength(1));
    });
  });

  group('a dedicated container', () {
    const dedicated = ContainerSpec(
      image: 'redis:7-alpine',
      exposedPorts: [6379],
      waitFor: WaitFor.healthy(),
      healthcheck: Healthcheck(test: ['CMD', 'true']),
      lifetime: Lifetime.dedicated,
    );

    final own = useContainer(
      dedicated,
      project: 'demo',
      stateDir: StateDir(tmp),
    );

    test('gets its own container', () {
      expect(own.reused, isFalse);
      expect(own.lifetime, Lifetime.dedicated);
    });
  });
}
