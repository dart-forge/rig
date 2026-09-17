import 'package:rig/engine.dart';
import 'package:rig/fake_engine.dart';
import 'package:rig/rig.dart';
import 'package:test/test.dart';

void main() {
  late FakeDockerEngine engine;

  setUp(() => engine = FakeDockerEngine());

  const spec = ContainerSpec(
    image: 'postgres:16-alpine',
    exposedPorts: [5432],
    waitFor: WaitFor.healthy(),
  );

  test('create then start then inspect yields a mapped host port', () async {
    final id = await engine.createContainer(spec, {rigHashLabel: 'h'});
    await engine.startContainer(id);

    final inspected = await engine.inspectContainer(id);

    expect(inspected.running, isTrue);
    expect(inspected.hostPorts.keys, [5432]);
    expect(inspected.hostPorts[5432], greaterThan(1024));
  });

  test('a created container is not running until started', () async {
    final id = await engine.createContainer(spec, const {});

    expect((await engine.inspectContainer(id)).running, isFalse);
  });

  test('records the spec and labels it was asked to create', () async {
    await engine.createContainer(spec, {rigHashLabel: 'abc'});

    expect(engine.lastCreatedSpec?.image, 'postgres:16-alpine');
    expect(engine.lastCreatedLabels?[rigHashLabel], 'abc');
  });

  test('records every call in order', () async {
    final id = await engine.createContainer(spec, const {});
    await engine.startContainer(id);
    await engine.stopContainer(id);

    expect(engine.calls, ['create', 'start:$id', 'stop:$id']);
  });

  test('health follows the queued sequence and holds the last value', () async {
    final id = await engine.createContainer(spec, const {});
    engine.queueHealth(id, [
      HealthStatus.starting,
      HealthStatus.starting,
      HealthStatus.healthy,
    ]);

    expect((await engine.inspectContainer(id)).health, HealthStatus.starting);
    expect((await engine.inspectContainer(id)).health, HealthStatus.starting);
    expect((await engine.inspectContainer(id)).health, HealthStatus.healthy);
    expect((await engine.inspectContainer(id)).health, HealthStatus.healthy);
  });

  test('reports no health when the spec has no healthcheck', () async {
    final id = await engine.createContainer(spec, const {});

    expect((await engine.inspectContainer(id)).health, HealthStatus.none);
  });

  test('a created container with a healthcheck reaches healthy', () async {
    // Staying at `starting` forever would make every caller that waits on
    // health time out against the fake while working against Docker.
    const withProbe = ContainerSpec(
      image: 'postgres:16-alpine',
      exposedPorts: [5432],
      waitFor: WaitFor.healthy(),
      healthcheck: Healthcheck(test: ['CMD', 'true']),
    );

    final id = await engine.createContainer(withProbe, const {});

    expect((await engine.inspectContainer(id)).health, HealthStatus.starting);
    expect((await engine.inspectContainer(id)).health, HealthStatus.healthy);
    expect((await engine.inspectContainer(id)).health, HealthStatus.healthy);
  });

  test('a created container can be made to stay unhealthy', () async {
    const withProbe = ContainerSpec(
      image: 'postgres:16-alpine',
      waitFor: WaitFor.healthy(),
      healthcheck: Healthcheck(test: ['CMD', 'false']),
    );
    engine.healthAfterCreate = const [HealthStatus.starting];

    final id = await engine.createContainer(withProbe, const {});

    expect((await engine.inspectContainer(id)).health, HealthStatus.starting);
    expect((await engine.inspectContainer(id)).health, HealthStatus.starting);
  });

  test('lists containers filtered by label', () async {
    final mine = engine.addContainer(labels: {rigHashLabel: 'wanted'});
    engine.addContainer(labels: {rigHashLabel: 'other'});
    engine.addContainer(labels: const {});

    final found = await engine.listContainers(
      filters: {
        'label': ['$rigHashLabel=wanted'],
      },
    );

    expect(found.map((c) => c.id), [mine]);
  });

  test('filters by state as well', () async {
    engine.addContainer(labels: {rigMarkerLabel: '1'}, state: 'exited');
    final running = engine.addContainer(
      labels: {rigMarkerLabel: '1'},
      state: 'running',
    );

    final found = await engine.listContainers(
      filters: {
        'label': ['$rigMarkerLabel=1'],
        'status': ['running'],
      },
    );

    expect(found.map((c) => c.id), [running]);
  });

  test('removing a container takes it out of the listing', () async {
    final id = engine.addContainer(labels: {rigMarkerLabel: '1'});

    await engine.removeContainer(id);

    expect(await engine.listContainers(), isEmpty);
  });

  test('stopping a container leaves it listed but not running', () async {
    final id = engine.addContainer(labels: {rigMarkerLabel: '1'});

    await engine.stopContainer(id);

    expect((await engine.inspectContainer(id)).running, isFalse);
    expect(await engine.listContainers(), hasLength(1));
  });

  test('starting a stopped container makes it running again', () async {
    final id = engine.addContainer(labels: const {}, state: 'exited');

    await engine.startContainer(id);

    expect((await engine.inspectContainer(id)).running, isTrue);
  });

  test('imageExists reflects what was pulled', () async {
    expect(await engine.imageExists('redis:7'), isFalse);

    await engine.pullImage('redis:7');

    expect(await engine.imageExists('redis:7'), isTrue);
  });

  test('a pull can be made to fail', () async {
    engine.pullSucceeds = false;
    engine.pullFailureDetail = 'manifest unknown';

    expect(
      () => engine.pullImage('nope:1'),
      throwsA(
        isA<ImagePullFailed>().having(
          (e) => e.message,
          'message',
          contains('manifest unknown'),
        ),
      ),
    );
  });

  test('ping can be made to fail', () async {
    engine.pingError = const DockerUnavailable(searched: ['/fake.sock']);

    expect(() => engine.ping(), throwsA(isA<DockerUnavailable>()));
  });

  test('log tail returns what was set', () async {
    final id = engine.addContainer(labels: const {});
    engine.setLogs(id, 'FATAL: nope');

    expect(await engine.logTail(id), 'FATAL: nope');
  });

  test('exec answers with what the test scripted', () async {
    final id = engine.addContainer(labels: const {});
    engine.onExec = (command) => command.any((c) => c.contains('CREATE'))
        ? const ExecResult(exitCode: 0, output: 'CREATE DATABASE')
        : const ExecResult(exitCode: 1, output: 'nope');

    expect(
      (await engine.exec(id, ['psql', '-c', 'CREATE DATABASE x'])).output,
      'CREATE DATABASE',
    );
    expect((await engine.exec(id, ['psql', '-c', 'SELECT 1'])).exitCode, 1);
  });

  test('exec defaults to success with no output', () async {
    final id = engine.addContainer(labels: const {});

    final result = await engine.exec(id, ['true']);

    expect(result.exitCode, 0);
    expect(result.output, isEmpty);
  });

  test('exec records the command it was given', () async {
    final id = engine.addContainer(labels: const {});

    await engine.exec(id, ['psql', '-c', 'SELECT 1']);

    expect(engine.calls, contains('exec:$id:psql -c SELECT 1'));
  });
}
