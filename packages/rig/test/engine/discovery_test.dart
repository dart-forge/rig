import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rig/rig.dart';
import 'package:rig/src/engine/discovery.dart';
import 'package:test/test.dart';

void main() {
  late Directory home;

  setUp(() => home = Directory.systemTemp.createTempSync('rig_home_'));
  tearDown(() => home.deleteSync(recursive: true));

  /// Stands in for a real socket with a plain file: discovery only checks
  /// that something is there.
  String touch(String relative) {
    final f = File(p.join(home.path, relative))..createSync(recursive: true);
    f.writeAsStringSync('');
    return f.path;
  }

  void writeDockerConfig(String currentContext) {
    File(p.join(home.path, '.docker', 'config.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({'currentContext': currentContext}));
  }

  void writeContext(String dirName, String name, String host) {
    File(p.join(home.path, '.docker', 'contexts', 'meta', dirName, 'meta.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'Name': name,
          'Endpoints': {
            'docker': {'Host': host},
          },
        }),
      );
  }

  group('DOCKER_HOST', () {
    test('wins over everything else', () {
      final sock = touch('custom.sock');
      writeDockerConfig('desktop-linux');
      writeContext('aaa', 'desktop-linux', 'unix:///ignored.sock');

      final found = discoverDockerSocket(
        environment: {'DOCKER_HOST': 'unix://$sock'},
        home: home.path,
        wellKnown: const [],
      );

      expect(found.path, sock);
      expect(found.source, contains('DOCKER_HOST'));
    });

    test('accepts a bare path as well as a unix:// url', () {
      final sock = touch('bare.sock');

      final found = discoverDockerSocket(
        environment: {'DOCKER_HOST': sock},
        home: home.path,
        wellKnown: const [],
      );

      expect(found.path, sock);
    });

    test('rejects a tcp endpoint with a message that says why', () {
      expect(
        () => discoverDockerSocket(
          environment: {'DOCKER_HOST': 'tcp://10.0.0.5:2375'},
          home: home.path,
          wellKnown: const [],
        ),
        throwsA(
          isA<DockerUnavailable>().having(
            (e) => e.message,
            'message',
            allOf(contains('tcp://10.0.0.5:2375'), contains('unix socket')),
          ),
        ),
      );
    });

    test('is skipped when it points at something that is not there', () {
      final real = touch('real.sock');

      final found = discoverDockerSocket(
        environment: {'DOCKER_HOST': 'unix:///nope/absent.sock'},
        home: home.path,
        wellKnown: [real],
      );

      expect(found.path, real, reason: 'fall through rather than fail early');
    });
  });

  group('docker context', () {
    test(
      'resolves the current context by its Name, not its directory hash',
      () {
        final sock = touch('ctx.sock');
        writeDockerConfig('colima');
        writeContext('0000deadbeef', 'desktop-linux', 'unix:///wrong.sock');
        writeContext('1111cafebabe', 'colima', 'unix://$sock');

        final found = discoverDockerSocket(
          environment: const {},
          home: home.path,
          wellKnown: const [],
        );

        expect(found.path, sock);
        expect(found.source, contains('colima'));
      },
    );

    test('falls through to well-known paths for the default context', () {
      final sock = touch('wk.sock');
      writeDockerConfig('default');

      final found = discoverDockerSocket(
        environment: const {},
        home: home.path,
        wellKnown: [sock],
      );

      expect(found.path, sock);
      expect(found.source, contains('well-known'));
    });

    test('falls through when the context socket is gone', () {
      final sock = touch('wk.sock');
      writeDockerConfig('desktop-linux');
      writeContext('aaa', 'desktop-linux', 'unix:///gone.sock');

      final found = discoverDockerSocket(
        environment: const {},
        home: home.path,
        wellKnown: [sock],
      );

      expect(found.path, sock);
    });

    test('survives a malformed config.json', () {
      final sock = touch('wk.sock');
      File(p.join(home.path, '.docker', 'config.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{ this is not json');

      final found = discoverDockerSocket(
        environment: const {},
        home: home.path,
        wellKnown: [sock],
      );

      expect(found.path, sock);
    });

    test('survives a malformed meta.json', () {
      final sock = touch('wk.sock');
      writeDockerConfig('broken');
      File(p.join(home.path, '.docker', 'contexts', 'meta', 'x', 'meta.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('nope');

      final found = discoverDockerSocket(
        environment: const {},
        home: home.path,
        wellKnown: [sock],
      );

      expect(found.path, sock);
    });
  });

  group('well-known paths', () {
    test('takes the first one that exists', () {
      final second = touch('second.sock');

      final found = discoverDockerSocket(
        environment: const {},
        home: home.path,
        wellKnown: [p.join(home.path, 'first.sock'), second],
      );

      expect(found.path, second);
    });

    test('covers Docker Desktop, colima, Rancher and rootless', () {
      final paths = wellKnownSocketPaths(
        home: '/Users/x',
        environment: {'XDG_RUNTIME_DIR': '/run/user/1000'},
      );

      expect(paths, contains('/var/run/docker.sock'));
      expect(paths, contains('/Users/x/.docker/run/docker.sock'));
      expect(paths, contains('/Users/x/.colima/default/docker.sock'));
      expect(paths, contains('/Users/x/.rd/docker.sock'));
      expect(paths, contains('/run/user/1000/docker.sock'));
    });

    test('omits the rootless path when XDG_RUNTIME_DIR is unset', () {
      final paths = wellKnownSocketPaths(
        home: '/Users/x',
        environment: const {},
      );

      expect(paths.any((path) => path.contains('run/user')), isFalse);
    });
  });

  group('when nothing is found', () {
    test('lists every location it tried, in order', () {
      writeDockerConfig('desktop-linux');
      writeContext('aaa', 'desktop-linux', 'unix:///ctx-gone.sock');

      DockerUnavailable? thrown;
      try {
        discoverDockerSocket(
          environment: const {'DOCKER_HOST': 'unix:///env-gone.sock'},
          home: home.path,
          wellKnown: const ['/wk-one.sock', '/wk-two.sock'],
        );
      } on DockerUnavailable catch (e) {
        thrown = e;
      }

      expect(thrown, isNotNull);
      expect(thrown!.searched.join('\n'), contains('/env-gone.sock'));
      expect(thrown.searched.join('\n'), contains('/ctx-gone.sock'));
      expect(thrown.searched.join('\n'), contains('/wk-one.sock'));
      expect(thrown.searched.join('\n'), contains('/wk-two.sock'));
      expect(thrown.message, contains('Is Docker running?'));
    });

    test('says DOCKER_HOST was not set when it was not', () {
      DockerUnavailable? thrown;
      try {
        discoverDockerSocket(
          environment: const {},
          home: home.path,
          wellKnown: const [],
        );
      } on DockerUnavailable catch (e) {
        thrown = e;
      }

      expect(thrown!.searched.join('\n'), contains('not set'));
    });
  });
}
