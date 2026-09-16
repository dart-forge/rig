import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rig/rig.dart';
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
}
