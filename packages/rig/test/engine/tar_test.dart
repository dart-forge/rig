import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

    test(
      '.dockerignore keeps an excluded file out of the archive entirely',
      () async {
        writeFile('.dockerignore', 'secret.txt\n');
        writeFile('secret.txt', 'sh, do not tell docker');
        writeFile('Dockerfile', 'FROM alpine:3.20\n');

        final tar = buildContextTar(tmp, dockerfile: 'Dockerfile');
        final listing = await _listWithRealTar(tar);

        expect(listing, isNot(contains('secret.txt')));
        expect(listing, contains('Dockerfile'));
      },
    );
  });

  // Each of these follows the brief's semantics table: the results
  // `docker build` itself gave for the same `.dockerignore` line, measured
  // rather than assumed.
  group('listBuildContext interprets .dockerignore', () {
    test("a single '*' does not cross '/': '*.log' leaves sub/c.log alone", () {
      writeFile('.dockerignore', '*.log\n');
      writeFile('sub/c.log', 'not excluded');

      final paths = listBuildContext(tmp).map((e) => e.relativePath).toList();

      expect(paths, contains('sub/c.log'));
    });

    test('last match wins: *.log then !b.log keeps b.log', () {
      writeFile('.dockerignore', '*.log\n!b.log\n');
      writeFile('b.log', 'kept');

      final paths = listBuildContext(tmp).map((e) => e.relativePath).toList();

      expect(paths, contains('b.log'));
    });

    test('last match wins the other way too: !b.log then *.log drops b.log — '
        'negation does not always win', () {
      writeFile('.dockerignore', '!b.log\n*.log\n');
      writeFile('b.log', 'dropped');

      final paths = listBuildContext(tmp).map((e) => e.relativePath).toList();

      expect(paths, isNot(contains('b.log')));
    });

    test('** crosses directory boundaries: **/*.log excludes every level', () {
      writeFile('.dockerignore', '**/*.log\n');
      writeFile('a.log', 'excluded at root');
      writeFile('sub/c.log', 'excluded, nested');

      final paths = listBuildContext(tmp).map((e) => e.relativePath).toList();

      expect(paths, isNot(contains('a.log')));
      expect(paths, isNot(contains('sub/c.log')));
    });

    test('a directory pattern excludes everything under it', () {
      writeFile('.dockerignore', 'sub/deep\n');
      writeFile('sub/deep/d.log', 'excluded via the directory');
      writeFile('sub/other.txt', 'unrelated, kept');

      final paths = listBuildContext(tmp).map((e) => e.relativePath).toList();

      expect(paths, isNot(contains('sub/deep/d.log')));
      expect(paths, isNot(contains('sub/deep/')));
      expect(paths, contains('sub/other.txt'));
    });

    test('comments, blank lines, and surrounding whitespace are ignored', () {
      writeFile('.dockerignore', '# a comment\n\n   \n  *.log  \n');
      writeFile('a.log', 'excluded');
      writeFile('a.txt', 'kept');

      final paths = listBuildContext(tmp).map((e) => e.relativePath).toList();

      expect(paths, isNot(contains('a.log')));
      expect(paths, contains('a.txt'));
    });

    test('throws on a character class rather than guessing, naming the line '
        'and the pattern', () {
      writeFile('.dockerignore', 'ok.txt\n[a-z].txt\n');

      expect(
        () => listBuildContext(tmp),
        throwsA(
          isA<DockerignorePatternNotSupported>().having(
            (e) => e.message,
            'message',
            allOf(contains('line 2'), contains('[a-z].txt')),
          ),
        ),
      );
    });

    test('the Dockerfile named by build.dockerfile is always kept, even when '
        '.dockerignore excludes it', () {
      writeFile('.dockerignore', 'Dockerfile\n');
      writeFile('Dockerfile', 'FROM alpine:3.20\n');

      final kept = listBuildContext(
        tmp,
        dockerfile: 'Dockerfile',
      ).map((e) => e.relativePath).toList();
      expect(kept, contains('Dockerfile'));

      // Without naming it, the same file is excluded like anything else —
      // proving the previous assertion is the override actually working,
      // not .dockerignore failing to match "Dockerfile" at all.
      final unkept = listBuildContext(tmp).map((e) => e.relativePath).toList();
      expect(unkept, isNot(contains('Dockerfile')));
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

  group('readTarEntries / readSingleFileArchive', () {
    test(
      'reads a single-file archive the real tar binary built, not one this '
      'file wrote itself — a round trip through singleFileArchive and back '
      'would pass even if this reader shared a writer misunderstanding',
      () async {
        writeFile('greeting.txt', 'hello from the real tar binary');
        final tar = await _realTarOf(tmp, ['greeting.txt']);

        final content = readSingleFileArchive(
          tar,
          requestedPath: '/tmp/greeting.txt',
        );

        expect(utf8.decode(content), 'hello from the real tar binary');
      },
    );

    test('rejects a multi-entry archive (from the real tar binary) rather '
        'than silently returning the first entry', () async {
      writeFile('a.txt', 'a');
      writeFile('b.txt', 'b');
      final tar = await _realTarOf(tmp, ['a.txt', 'b.txt']);

      expect(
        () => readSingleFileArchive(tar, requestedPath: '/tmp/mystery'),
        throwsA(
          isA<UnexpectedArchiveContents>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('/tmp/mystery'),
              contains('a.txt'),
              contains('b.txt'),
            ),
          ),
        ),
      );
    });

    test('rejects a single directory entry, not just a directory with '
        'children', () async {
      Directory(p.join(tmp.path, 'onlydir')).createSync();
      final tar = await _realTarOf(tmp, ['onlydir']);

      expect(
        () => readSingleFileArchive(tar, requestedPath: '/tmp/onlydir'),
        throwsA(isA<UnexpectedArchiveContents>()),
      );
    });

    test('round-trips content, name, and — checked through the real tar '
        'binary\'s own listing, not this reader — uid/gid/mode written by '
        'singleFileArchive', () async {
      final tar = singleFileArchive(
        path: 'owned.txt',
        content: utf8.encode('payload'),
        mode: 0x1A4, // 644
        uid: 1000,
        gid: 1000,
      );

      final entries = readTarEntries(tar);
      expect(entries, hasLength(1));
      expect(entries.single.name, 'owned.txt');
      expect(entries.single.isRegularFile, isTrue);
      expect(utf8.decode(entries.single.content), 'payload');

      final listing = await _listWithRealTar(tar);
      // The two tars disagree on how to print an owner: BSD tar (macOS)
      // separates uid and gid with spaces, GNU tar (Linux) with a slash.
      // Accept either rather than pinning this test to one platform.
      expect(listing, matches(RegExp(r'\b1000[/\s]+1000\b')));
      expect(listing.split('\n').first, startsWith('-rw-r--r--'));
    });
  });

  group('parseFileMode', () {
    test('accepts 3 and 4 octal digits', () {
      expect(parseFileMode('644'), 0x1A4);
      expect(parseFileMode('0644'), 0x1A4);
      expect(parseFileMode('4755'), 0x9ED);
    });

    for (final bad in ['999', 'abc', '64', '12345', '']) {
      test('rejects "$bad" rather than silently misreading it', () {
        expect(
          () => parseFileMode(bad),
          throwsA(
            isA<InvalidFileMode>().having(
              (e) => e.message,
              'message',
              contains(bad),
            ),
          ),
        );
      });
    }
  });
}

/// Builds a tar with the real `tar` binary rather than [buildContextTar] or
/// [singleFileArchive] — the same reasoning [_listWithRealTar] and
/// [_extractWithRealTar] already apply to the writer, applied to the
/// reader: a tar nobody in this codebase wrote is the only thing that can
/// tell a correct reader apart from one that just agrees with its own
/// writer's mistakes. `--format ustar` pins the format explicitly, since
/// this reader only understands ustar's fixed-offset header, not GNU's or
/// pax's extensions.
Future<Uint8List> _realTarOf(Directory dir, List<String> relPaths) async {
  final process = await Process.start('tar', [
    '--format',
    'ustar',
    '-cf',
    '-',
    '-C',
    dir.path,
    ...relPaths,
  ]);
  final bytes = <int>[];
  final collected = process.stdout.forEach(bytes.addAll);
  await process.stdin.close();
  await collected;
  final code = await process.exitCode;
  if (code != 0) {
    final err = await process.stderr.transform(utf8.decoder).join();
    fail('tar --format ustar -cf - exited $code: $err');
  }
  return Uint8List.fromList(bytes);
}
