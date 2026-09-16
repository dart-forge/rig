import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rig/engine.dart';
import 'package:rig/rig.dart';
import 'package:rig/src/engine/api_parse.dart';
import 'package:rig/src/engine/http_engine.dart';
import 'package:test/test.dart';

import 'engine_server.dart';

void main() {
  late Directory tmp;
  late String socketPath;
  late FakeEngineServer server;
  late HttpDockerEngine engine;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('rig_engine_');
    // Unix socket paths are capped near 104 characters, so keep this short.
    socketPath = p.join(tmp.path, 'd.sock');
    server = await FakeEngineServer.start(socketPath);
    engine = HttpDockerEngine(socketPath: socketPath);
  });

  tearDown(() async {
    await engine.close();
    await server.close();
    tmp.deleteSync(recursive: true);
  });

  group('ping', () {
    test('succeeds when the daemon answers OK', () async {
      server.on('GET', '/v1.44/_ping', body: 'OK');

      await expectLater(engine.ping(), completes);
    });

    test('pins the API version into the path', () async {
      server.on('GET', '/v1.44/_ping', body: 'OK');

      await engine.ping();

      expect(server.requests.single.path, '/v1.44/_ping');
    });

    test('throws DockerUnavailable when the socket is not there', () async {
      final dead = HttpDockerEngine(
        socketPath: p.join(tmp.path, 'absent.sock'),
      );

      await expectLater(
        dead.ping(),
        throwsA(
          isA<DockerUnavailable>().having(
            (e) => e.message,
            'message',
            contains('absent.sock'),
          ),
        ),
      );
      await dead.close();
    });

    test('throws DockerUnavailable when the daemon answers an error', () async {
      server.on('GET', '/v1.44/_ping', status: 500, body: 'boom');

      await expectLater(engine.ping(), throwsA(isA<DockerUnavailable>()));
    });
  });

  group('version', () {
    test('reads the three version fields', () async {
      server.on(
        'GET',
        '/v1.44/version',
        json: {
          'Version': '29.5.3',
          'ApiVersion': '1.54',
          'MinAPIVersion': '1.40',
        },
      );

      final v = await engine.version();

      expect(v.version, '29.5.3');
      expect(v.apiVersion, '1.54');
      expect(v.minApiVersion, '1.40');
    });
  });

  group('ensureApiCompatible', () {
    test('passes when the daemon still accepts 1.44', () async {
      server.on(
        'GET',
        '/v1.44/version',
        json: {
          'Version': '29.5.3',
          'ApiVersion': '1.54',
          'MinAPIVersion': '1.40',
        },
      );

      await expectLater(engine.ensureApiCompatible(), completes);
    });

    test('passes when the minimum is exactly 1.44', () async {
      server.on(
        'GET',
        '/v1.44/version',
        json: {
          'Version': '40.0.0',
          'ApiVersion': '1.60',
          'MinAPIVersion': '1.44',
        },
      );

      await expectLater(engine.ensureApiCompatible(), completes);
    });

    test('fails clearly when the daemon dropped 1.44', () async {
      server.on(
        'GET',
        '/v1.44/version',
        json: {
          'Version': '45.0.0',
          'ApiVersion': '1.70',
          'MinAPIVersion': '1.50',
        },
      );

      await expectLater(
        engine.ensureApiCompatible(),
        throwsA(
          isA<EngineApiTooOld>().having(
            (e) => e.message,
            'message',
            contains('1.50'),
          ),
        ),
      );
    });

    test('compares numerically, not as strings', () async {
      // '1.9' < '1.44' numerically, but '1.9' > '1.44' as text.
      server.on(
        'GET',
        '/v1.44/version',
        json: {
          'Version': '20.0.0',
          'ApiVersion': '1.41',
          'MinAPIVersion': '1.9',
        },
      );

      await expectLater(engine.ensureApiCompatible(), completes);
    });
  });

  group('createContainer', () {
    setUp(() {
      server.on(
        'POST',
        '/v1.44/containers/create',
        status: 201,
        json: {'Id': 'newcontainer123', 'Warnings': <String>[]},
      );
    });

    Map<String, Object?> lastCreateBody() => server.requests
        .lastWhere((r) => r.path.startsWith('/v1.44/containers/create'))
        .json;

    test('returns the new container id', () async {
      final id = await engine.createContainer(
        const ContainerSpec(image: 'x', waitFor: WaitFor.healthy()),
        const {},
      );

      expect(id, 'newcontainer123');
    });

    test(
      'asks Docker to pick the host port, by sending an empty HostPort',
      () async {
        await engine.createContainer(
          const ContainerSpec(
            image: 'postgres:16-alpine',
            exposedPorts: [5432],
            waitFor: WaitFor.healthy(),
          ),
          const {},
        );

        final body = lastCreateBody();
        final hostConfig = body['HostConfig'] as Map<String, Object?>;
        final bindings = hostConfig['PortBindings'] as Map<String, Object?>;
        final forPort =
            (bindings['5432/tcp'] as List).single as Map<String, Object?>;

        expect(
          forPort['HostPort'],
          '',
          reason: 'an empty HostPort is what makes Docker choose a free one',
        );
        expect(forPort['HostIp'], '127.0.0.1');
        expect(
          body['ExposedPorts'],
          containsPair('5432/tcp', isA<Map<String, Object?>>()),
        );
      },
    );

    test('sends env as KEY=VALUE strings', () async {
      await engine.createContainer(
        const ContainerSpec(
          image: 'x',
          env: {'POSTGRES_USER': 'test', 'POSTGRES_DB': 'test_db'},
          waitFor: WaitFor.healthy(),
        ),
        const {},
      );

      expect(
        lastCreateBody()['Env'],
        containsAll(['POSTGRES_USER=test', 'POSTGRES_DB=test_db']),
      );
    });

    test('sends the command and omits an empty entrypoint', () async {
      await engine.createContainer(
        const ContainerSpec(
          image: 'x',
          command: ['postgres', '-c', 'log_statement=all'],
          waitFor: WaitFor.healthy(),
        ),
        const {},
      );

      final body = lastCreateBody();
      expect(body['Cmd'], ['postgres', '-c', 'log_statement=all']);
      expect(body.containsKey('Entrypoint'), isFalse);
    });

    test('sends the labels it was given, not the spec own labels', () async {
      await engine.createContainer(
        const ContainerSpec(
          image: 'x',
          waitFor: WaitFor.healthy(),
          labels: {'ignored': 'yes'},
        ),
        const {'org.rig': '1', 'org.rig.hash': 'abc'},
      );

      final labels = lastCreateBody()['Labels'] as Map<String, Object?>;
      expect(labels['org.rig.hash'], 'abc');
      expect(
        labels.containsKey('ignored'),
        isFalse,
        reason: 'merging is the caller job, so it happens exactly once',
      );
    });

    test('sends healthcheck durations in nanoseconds', () async {
      await engine.createContainer(
        const ContainerSpec(
          image: 'x',
          waitFor: WaitFor.healthy(),
          healthcheck: Healthcheck(
            test: ['CMD-SHELL', 'pg_isready -h 127.0.0.1 -U test'],
            interval: Duration(milliseconds: 250),
            timeout: Duration(seconds: 3),
            retries: 40,
            startPeriod: Duration(seconds: 1),
          ),
        ),
        const {},
      );

      final hc = lastCreateBody()['Healthcheck'] as Map<String, Object?>;
      expect(hc['Test'], ['CMD-SHELL', 'pg_isready -h 127.0.0.1 -U test']);
      expect(hc['Interval'], 250 * 1000 * 1000);
      expect(hc['Timeout'], 3 * 1000 * 1000 * 1000);
      expect(hc['Retries'], 40);
      expect(hc['StartPeriod'], 1000 * 1000 * 1000);
    });

    test('omits the healthcheck entirely when the spec has none', () async {
      await engine.createContainer(
        const ContainerSpec(image: 'x', waitFor: WaitFor.port(1)),
        const {},
      );

      expect(
        lastCreateBody().containsKey('Healthcheck'),
        isFalse,
        reason: 'sending an empty one would override the image own',
      );
    });

    test('sends tmpfs as a map of path to empty options', () async {
      await engine.createContainer(
        const ContainerSpec(
          image: 'x',
          tmpfs: {'/var/lib/postgresql/data'},
          waitFor: WaitFor.healthy(),
        ),
        const {},
      );

      final hostConfig = lastCreateBody()['HostConfig'] as Map<String, Object?>;
      expect(hostConfig['Tmpfs'], containsPair('/var/lib/postgresql/data', ''));
    });

    test('sends mounts as bind strings with the access mode', () async {
      await engine.createContainer(
        const ContainerSpec(
          image: 'x',
          waitFor: WaitFor.healthy(),
          mounts: [
            Mount(hostPath: '/h/server.crt', containerPath: '/c/server.crt'),
            Mount(
              hostPath: '/h/data',
              containerPath: '/c/data',
              readOnly: false,
            ),
          ],
        ),
        const {},
      );

      final hostConfig = lastCreateBody()['HostConfig'] as Map<String, Object?>;
      expect(hostConfig['Binds'], [
        '/h/server.crt:/c/server.crt:ro',
        '/h/data:/c/data:rw',
      ]);
    });

    test(
      'sends user, workingDir, privileged and networkMode when set',
      () async {
        await engine.createContainer(
          const ContainerSpec(
            image: 'x',
            waitFor: WaitFor.healthy(),
            user: '1000:1000',
            workingDir: '/app',
            privileged: true,
            networkMode: 'host',
          ),
          const {},
        );

        final body = lastCreateBody();
        final hostConfig = body['HostConfig'] as Map<String, Object?>;
        expect(body['User'], '1000:1000');
        expect(body['WorkingDir'], '/app');
        expect(hostConfig['Privileged'], isTrue);
        expect(hostConfig['NetworkMode'], 'host');
      },
    );

    test('never asks for AutoRemove', () async {
      await engine.createContainer(
        const ContainerSpec(image: 'x', waitFor: WaitFor.healthy()),
        const {},
      );

      final hostConfig = lastCreateBody()['HostConfig'] as Map<String, Object?>;
      expect(
        hostConfig['AutoRemove'],
        isFalse,
        reason:
            'a container that vanishes on exit cannot be inspected '
            'after a failure, and shared ones must outlive the run',
      );
    });
  });

  group('startContainer', () {
    test('posts to the start endpoint', () async {
      server.on('POST', '/v1.44/containers/abc/start', status: 204);

      await engine.startContainer('abc');

      expect(server.requests.single.method, 'POST');
      expect(server.requests.single.path, '/v1.44/containers/abc/start');
    });

    test('treats 304 (already started) as success', () async {
      server.on('POST', '/v1.44/containers/abc/start', status: 304);

      await expectLater(engine.startContainer('abc'), completes);
    });
  });

  group('inspectContainer', () {
    test('reads the host port Docker chose', () async {
      server.on(
        'GET',
        '/v1.44/containers/abc/json',
        json: {
          'Id': 'abc',
          'Created': '2026-09-16T12:00:00.000000000Z',
          'Config': {
            'Labels': {'org.rig': '1'},
          },
          'State': {
            'Running': true,
            'Health': {'Status': 'healthy'},
          },
          'NetworkSettings': {
            'Ports': {
              '5432/tcp': [
                {'HostIp': '127.0.0.1', 'HostPort': '54321'},
              ],
            },
          },
        },
      );

      final inspected = await engine.inspectContainer('abc');

      expect(inspected.id, 'abc');
      expect(inspected.running, isTrue);
      expect(inspected.health, HealthStatus.healthy);
      expect(inspected.hostPorts, {5432: 54321});
      expect(inspected.labels['org.rig'], '1');
      expect(inspected.created.year, 2026);
    });

    test('prefers the IPv4 binding when Docker publishes both', () async {
      server.on(
        'GET',
        '/v1.44/containers/abc/json',
        json: {
          'Id': 'abc',
          'Created': '2026-09-16T12:00:00Z',
          'Config': {'Labels': <String, String>{}},
          'State': {'Running': true},
          'NetworkSettings': {
            'Ports': {
              '5432/tcp': [
                {'HostIp': '::', 'HostPort': '60000'},
                {'HostIp': '0.0.0.0', 'HostPort': '54321'},
              ],
            },
          },
        },
      );

      expect((await engine.inspectContainer('abc')).hostPorts, {5432: 54321});
    });

    test('skips a port with no binding yet', () async {
      server.on(
        'GET',
        '/v1.44/containers/abc/json',
        json: {
          'Id': 'abc',
          'Created': '2026-09-16T12:00:00Z',
          'Config': {'Labels': <String, String>{}},
          'State': {'Running': false},
          'NetworkSettings': {
            'Ports': {'5432/tcp': null},
          },
        },
      );

      expect((await engine.inspectContainer('abc')).hostPorts, isEmpty);
    });

    test('reports no health when the container has no healthcheck', () async {
      server.on(
        'GET',
        '/v1.44/containers/abc/json',
        json: {
          'Id': 'abc',
          'Created': '2026-09-16T12:00:00Z',
          'Config': {'Labels': <String, String>{}},
          'State': {'Running': true},
          'NetworkSettings': {'Ports': <String, Object?>{}},
        },
      );

      expect((await engine.inspectContainer('abc')).health, HealthStatus.none);
    });

    test('maps every health status Docker reports', () async {
      expect(parseHealthStatus({'Status': 'starting'}), HealthStatus.starting);
      expect(parseHealthStatus({'Status': 'healthy'}), HealthStatus.healthy);
      expect(
        parseHealthStatus({'Status': 'unhealthy'}),
        HealthStatus.unhealthy,
      );
      expect(parseHealthStatus({'Status': 'none'}), HealthStatus.none);
      expect(parseHealthStatus(null), HealthStatus.none);
      expect(parseHealthStatus({'Status': 'brand-new'}), HealthStatus.none);
    });
  });

  group('errors from the daemon', () {
    test(
      'an error status becomes EngineError with method, path and body',
      () async {
        server.on(
          'POST',
          '/v1.44/containers/create',
          status: 409,
          json: {'message': 'Conflict. The name is in use'},
        );

        await expectLater(
          engine.createContainer(
            const ContainerSpec(image: 'x', waitFor: WaitFor.healthy()),
            const {},
          ),
          throwsA(
            isA<EngineError>()
                .having((e) => e.statusCode, 'statusCode', 409)
                .having((e) => e.method, 'method', 'POST')
                .having((e) => e.path, 'path', contains('/containers/create'))
                .having((e) => e.body, 'body', contains('name is in use')),
          ),
        );
      },
    );

    test('a 404 on inspect is an EngineError, not a null', () async {
      server.on(
        'GET',
        '/v1.44/containers/',
        status: 404,
        json: {'message': 'No such container'},
      );

      await expectLater(
        engine.inspectContainer('gone'),
        throwsA(isA<EngineError>().having((e) => e.statusCode, 'status', 404)),
      );
    });
  });
}
