import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rig/engine.dart';
import 'package:rig/fake_engine.dart';
import 'package:rig/rig.dart';
import 'package:rig/src/engine/tar.dart';
import 'package:test/test.dart';

void main() {
  late FakeDockerEngine engine;

  setUp(() => engine = FakeDockerEngine());

  AcquiredContainer acquired({
    String id = 'cid',
    Map<int, int> ports = const {5432: 54321},
    Lifetime lifetime = Lifetime.shared,
    bool reused = false,
  }) => AcquiredContainer(
    containerId: id,
    host: '127.0.0.1',
    hostPorts: ports,
    lifetime: lifetime,
    reused: reused,
    hash: 'h',
  );

  test('exposes the host and the mapped port', () {
    final lease = ContainerLease.of(engine, acquired());

    expect(lease.host, '127.0.0.1');
    expect(lease.port(5432), 54321);
    expect(lease.endpoint(5432), '127.0.0.1:54321');
  });

  test('names the ports that are published when asked for another', () {
    final lease = ContainerLease.of(
      engine,
      acquired(ports: {5432: 1, 8080: 2}),
    );

    expect(
      () => lease.port(9999),
      throwsA(
        isA<PortNotPublished>()
            .having((e) => e.message, 'message', contains('9999'))
            .having((e) => e.message, 'message', contains('5432'))
            .having((e) => e.message, 'message', contains('8080')),
      ),
    );
  });

  test(
    'reading before the container is acquired says where to move the read',
    () {
      final lease = ContainerLease.pending(() => engine);

      expect(() => lease.host, throwsA(isA<LeaseNotBound>()));
      expect(() => lease.port(5432), throwsA(isA<LeaseNotBound>()));
      expect(() => lease.containerId, throwsA(isA<LeaseNotBound>()));
    },
  );

  test('binding makes it readable', () {
    final lease = ContainerLease.pending(() => engine)..bind(acquired());

    expect(lease.port(5432), 54321);
  });

  group('release', () {
    test('leaves a shared container running', () async {
      final lease = ContainerLease.of(engine, acquired());

      await lease.release();

      expect(
        engine.calls,
        isEmpty,
        reason: 'the next run should not pay for startup again',
      );
    });

    test('stops and removes a dedicated container', () async {
      final id = engine.addContainer(labels: const {});
      final lease = ContainerLease.of(
        engine,
        acquired(id: id, lifetime: Lifetime.dedicated),
      );

      await lease.release();

      expect(engine.calls, ['stop:$id', 'remove:$id']);
    });

    test('is safe to call twice', () async {
      final id = engine.addContainer(labels: const {});
      final lease = ContainerLease.of(
        engine,
        acquired(id: id, lifetime: Lifetime.dedicated),
      );

      await lease.release();
      await lease.release();

      expect(engine.calls, ['stop:$id', 'remove:$id']);
    });

    test('reports the same failure again on retry, rather than a silent '
        'no-op that leaves the container stopped but never removed', () async {
      final id = engine.addContainer(labels: const {});
      final lease = ContainerLease.of(
        engine,
        acquired(id: id, lifetime: Lifetime.dedicated),
      );
      engine.removeError = StateError('boom');

      await expectLater(lease.release(), throwsA(isA<StateError>()));
      await expectLater(
        lease.release(),
        throwsA(isA<StateError>()),
        reason:
            'a caller retrying after a real failure must be told again, '
            'not handed a false success',
      );

      expect(engine.calls, [
        'stop:$id',
        'remove:$id',
      ], reason: 'one attempt, reported twice — not one attempt per call');
    });

    test('does nothing when the container was never acquired', () async {
      await expectLater(
        ContainerLease.pending(() => engine).release(),
        completes,
      );
      expect(engine.calls, isEmpty);
    });
  });

  test('log tail comes from the engine', () async {
    final id = engine.addContainer(labels: const {});
    engine.setLogs(id, 'some output');
    final lease = ContainerLease.of(engine, acquired(id: id));

    expect(await lease.logTail(), 'some output');
  });

  test('reports whether the container was reused', () {
    expect(ContainerLease.of(engine, acquired(reused: true)).reused, isTrue);
    expect(ContainerLease.of(engine, acquired(reused: false)).reused, isFalse);
  });

  group('exec', () {
    test('returns the exit code and output of a successful command', () async {
      final id = engine.addContainer(labels: const {});
      engine.onExec = (_) => const ExecResult(exitCode: 0, output: 'ok\n');
      final lease = ContainerLease.of(engine, acquired(id: id));

      final result = await lease.exec(['echo', 'ok']);

      expect(result.exitCode, 0);
      expect(result.output, 'ok\n');
    });

    test('throws ExecFailed on a non-zero exit, with the command, exit code '
        'and output all present in the message', () async {
      final id = engine.addContainer(labels: const {});
      // The command, exit code and output deliberately share no digits or
      // words: if they did, a message missing one of them could still pass
      // by coincidentally containing another.
      engine.onExec = (_) =>
          const ExecResult(exitCode: 7, output: 'boom: disk is full');
      final lease = ContainerLease.of(engine, acquired(id: id));

      await expectLater(
        lease.exec(['sh', '-c', 'do-the-thing']),
        throwsA(
          isA<ExecFailed>()
              .having((e) => e.command, 'command', ['sh', '-c', 'do-the-thing'])
              .having((e) => e.exitCode, 'exitCode', 7)
              .having(
                (e) => e.message,
                'message',
                allOf(
                  contains('sh -c do-the-thing'),
                  contains('7'),
                  contains('boom: disk is full'),
                ),
              ),
        ),
      );
    });

    test('does not throw when expectSuccess is false, and still returns the '
        'result', () async {
      final id = engine.addContainer(labels: const {});
      engine.onExec = (_) => const ExecResult(exitCode: 3, output: 'boom');
      final lease = ContainerLease.of(engine, acquired(id: id));

      final result = await lease.exec([
        'sh',
        '-c',
        'exit 3',
      ], expectSuccess: false);

      expect(result.exitCode, 3);
      expect(result.output, 'boom');
    });

    test(
      'throws LeaseNotBound when called before the container is acquired',
      () async {
        final lease = ContainerLease.pending(() => engine);

        await expectLater(
          lease.exec(['echo', 'hi']),
          throwsA(isA<LeaseNotBound>()),
        );
      },
    );
  });

  group('putFile', () {
    test('rejects a mode that is not 3-4 octal digits, without touching the '
        'engine at all', () async {
      final id = engine.addContainer(labels: const {});
      final lease = ContainerLease.of(engine, acquired(id: id));

      await expectLater(
        lease.putFile('/data/f.txt', utf8.encode('x'), mode: '999'),
        throwsA(isA<InvalidFileMode>()),
      );
      expect(
        engine.calls,
        isEmpty,
        reason:
            'a bad mode must be caught before any archive is built or '
            'sent, not discovered by Docker',
      );
    });

    test('round-trips content through putArchive/getArchive exactly, byte '
        'for byte', () async {
      final id = engine.addContainer(labels: const {});
      final lease = ContainerLease.of(engine, acquired(id: id));

      // '/' is present on every container by default, so this exercises
      // the round trip without also depending on addDirectory.
      await lease.putFile('/f.txt', utf8.encode('exact bytes'));
      final readBack = await lease.getFile('/f.txt');

      expect(utf8.decode(readBack), 'exact bytes');
    });

    test('throws CopyDestinationNotFound when the destination directory does '
        'not exist, rather than creating it', () async {
      final id = engine.addContainer(labels: const {});
      final lease = ContainerLease.of(engine, acquired(id: id));

      await expectLater(
        lease.putFile('/nope/deep/f.txt', utf8.encode('x')),
        throwsA(
          isA<CopyDestinationNotFound>()
              .having((e) => e.directory, 'directory', '/nope/deep')
              .having((e) => e.message, 'message', contains('/nope/deep')),
        ),
      );
    });

    test('succeeds once the destination directory is made to exist', () async {
      final id = engine.addContainer(labels: const {});
      engine.addDirectory(id, '/data');
      final lease = ContainerLease.of(engine, acquired(id: id));

      await lease.putFile('/data/f.txt', utf8.encode('ok'));

      expect(utf8.decode(await lease.getFile('/data/f.txt')), 'ok');
    });
  });

  group('getFile', () {
    test('throws UnexpectedArchiveContents when the archive holds more '
        'than one entry, rather than silently returning the first', () async {
      final id = engine.addContainer(labels: const {});
      final tmp = Directory.systemTemp.createTempSync('rig_lease_tar_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      File(p.join(tmp.path, 'a.txt')).writeAsStringSync('a');
      File(p.join(tmp.path, 'b.txt')).writeAsStringSync('b');
      engine.addRawArchive(id, '/data', directoryArchive(tmp, uid: 0, gid: 0));
      final lease = ContainerLease.of(engine, acquired(id: id));

      await expectLater(
        lease.getFile('/data'),
        throwsA(
          isA<UnexpectedArchiveContents>()
              .having((e) => e.message, 'message', contains('/data'))
              .having((e) => e.message, 'message', contains('a.txt'))
              .having((e) => e.message, 'message', contains('b.txt')),
        ),
      );
    });
  });

  group('copyInto', () {
    test('copies a single host file in under its own basename', () async {
      final id = engine.addContainer(labels: const {});
      engine.addDirectory(id, '/data');
      final tmp = Directory.systemTemp.createTempSync('rig_lease_copy_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      File(p.join(tmp.path, 'source.txt')).writeAsStringSync('host content');
      final lease = ContainerLease.of(engine, acquired(id: id));

      await lease.copyInto(p.join(tmp.path, 'source.txt'), '/data');

      expect(
        utf8.decode(await lease.getFile('/data/source.txt')),
        'host content',
      );
    });

    test('copies a host directory\'s contents into the destination, not the '
        'directory itself', () async {
      final id = engine.addContainer(labels: const {});
      engine.addDirectory(id, '/data');
      final tmp = Directory.systemTemp.createTempSync('rig_lease_copydir_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      File(p.join(tmp.path, 'one.txt')).writeAsStringSync('one');
      Directory(p.join(tmp.path, 'sub')).createSync();
      File(p.join(tmp.path, 'sub', 'two.txt')).writeAsStringSync('two');
      final lease = ContainerLease.of(engine, acquired(id: id));

      await lease.copyInto(tmp.path, '/data');

      expect(utf8.decode(await lease.getFile('/data/one.txt')), 'one');
      expect(utf8.decode(await lease.getFile('/data/sub/two.txt')), 'two');
    });

    test('throws CopyDestinationNotFound when the destination directory does '
        'not exist', () async {
      final id = engine.addContainer(labels: const {});
      final tmp = Directory.systemTemp.createTempSync('rig_lease_copy_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      File(p.join(tmp.path, 'f.txt')).writeAsStringSync('x');
      final lease = ContainerLease.of(engine, acquired(id: id));

      await expectLater(
        lease.copyInto(p.join(tmp.path, 'f.txt'), '/nope'),
        throwsA(isA<CopyDestinationNotFound>()),
      );
    });
  });
}
