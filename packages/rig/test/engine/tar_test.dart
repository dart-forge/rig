import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rig/rig.dart';
import 'package:rig/src/engine/tar.dart';
import 'package:test/test.dart';

/// Pipes [tar] into the real `tar` binary and returns what it printed.
///
/// The point, per the design this implements: checking a hand-written ustar
/// writer against a hand-written reader proves nothing except that the two
/// share the same misunderstanding. Only a tar nobody here wrote can tell
/// this apart from a broken one.
Future<String> _listWithRealTar(List<int> tar) async {
  final process = await Process.start('tar', ['-tvf', '-']);
  process.stdin.add(tar);
  await process.stdin.close();
  final out = await process.stdout.transform(utf8.decoder).join();
  final code = await process.exitCode;
  if (code != 0) {
    final err = await process.stderr.transform(utf8.decoder).join();
    fail('tar -tvf - exited $code: $err');
  }
  return out;
}

Future<String> _extractWithRealTar(List<int> tar, String path) async {
  final process = await Process.start('tar', ['-xOf', '-', path]);
  process.stdin.add(tar);
  await process.stdin.close();
  final out = await process.stdout.transform(utf8.decoder).join();
  final code = await process.exitCode;
  if (code != 0) {
    final err = await process.stderr.transform(utf8.decoder).join();
    fail('tar -xOf - $path exited $code: $err');
  }
  return out;
}

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('rig_tar_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  File writeFile(String relPath, String content) {
    final file = File(p.join(tmp.path, relPath))..createSync(recursive: true);
    return file..writeAsStringSync(content);
  }

  group('buildContextTar', () {
    test(
      'the real tar binary can list every file and directory written',
      () async {
        writeFile('Dockerfile', 'FROM alpine:3.20\n');
        writeFile('sub/nested.txt', 'nested content');

        final tar = buildContextTar(tmp);
        final listing = await _listWithRealTar(tar);

        expect(listing, contains('Dockerfile'));
        expect(listing, contains('sub/'));
        expect(listing, contains('sub/nested.txt'));
      },
    );

    test('file content round-trips through the real tar binary', () async {
      writeFile('data.txt', 'exact bytes, nothing added or dropped');

      final tar = buildContextTar(tmp);

      expect(
        await _extractWithRealTar(tar, 'data.txt'),
        'exact bytes, nothing added or dropped',
      );
    });

    test(
      'the executable bit survives, as reported by the real tar binary',
      () async {
        final script = writeFile('run.sh', '#!/bin/sh\necho hi\n');
        await Process.run('chmod', ['755', script.path]);
        writeFile('data.txt', 'not executable');
        await Process.run('chmod', [
          '644',
          File(p.join(tmp.path, 'data.txt')).path,
        ]);

        final listing = await _listWithRealTar(buildContextTar(tmp));

        final lines = listing.split('\n');
        expect(
          lines.firstWhere((l) => l.contains('run.sh')),
          startsWith('-rwxr-xr-x'),
        );
        expect(
          lines.firstWhere((l) => l.contains('data.txt')),
          startsWith('-rw-r--r--'),
        );
      },
    );

    test(
      'a path that needs ustar prefix/name splitting still round-trips',
      () async {
        // 70-byte segments: long enough that the whole path cannot fit in
        // the 100-byte name field alone, short enough that a valid
        // prefix(155)/name(100) split exists.
        final dir1 = 'a' * 70;
        final dir2 = 'b' * 70;
        final fileName = 'c' * 80;
        final relPath = '$dir1/$dir2/$fileName';
        writeFile(relPath, 'deep content');

        final tar = buildContextTar(tmp);
        final listing = await _listWithRealTar(tar);
        expect(listing, contains(relPath));
        expect(await _extractWithRealTar(tar, relPath), 'deep content');
      },
    );

    test('rejects a symlink rather than following or skipping it', () {
      writeFile('real.txt', 'real');
      Link(p.join(tmp.path, 'link.txt')).createSync('real.txt');

      expect(() => buildContextTar(tmp), throwsA(isA<SymlinkInBuildContext>()));
    });

    test('rejects a path ustar cannot split into name and prefix', () {
      // No slash gives a split point anywhere near the end, so no split
      // can ever satisfy name<=100 and prefix<=155 at once.
      writeFile('${'x' * 90}/${'y' * 90}/${'z' * 90}', 'unreachable');

      expect(
        () => buildContextTar(tmp),
        throwsA(isA<BuildContextPathTooLong>()),
      );
    });

    test('rejects a .dockerignore rather than silently sending everything', () {
      writeFile('.dockerignore', 'secret.txt\n');
      writeFile('secret.txt', 'sh, do not tell docker');

      expect(
        () => buildContextTar(tmp),
        throwsA(isA<DockerignoreNotSupported>()),
      );
    });
  });

  group('listBuildContext', () {
    test('lists entries sorted by path, not filesystem order', () {
      writeFile('z.txt', 'z');
      writeFile('a.txt', 'a');
      writeFile('m/n.txt', 'n');

      final paths = listBuildContext(tmp).map((e) => e.relativePath).toList();

      expect(paths, [...paths]..sort());
    });

    test('carries the file mode read from the filesystem', () {
      final file = writeFile('script.sh', '#!/bin/sh\n');
      Process.runSync('chmod', ['750', file.path]);

      final entry = listBuildContext(tmp)
          .firstWhere((e) => e.relativePath == 'script.sh');

      expect(entry.mode, 0x1E8); // 0750
    });
  });
}
