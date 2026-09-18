import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rig/src/lease/state_dir.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('rig_state_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('lives under the home directory, not the system temp', () {
    final dir = StateDir.forUser(environment: {'HOME': '/Users/x'});

    expect(dir.root.path, '/Users/x/.rig');
  });

  test('lays out locks, failed markers, certs and per-kind markers', () {
    final dir = StateDir(Directory(tmp.path));

    expect(dir.lockPath('abc123'), p.join(tmp.path, 'locks', 'abc123.lock'));
    expect(
      dir.failedMarker('cid').path,
      p.join(tmp.path, 'failed', 'cid.json'),
    );
    expect(dir.failedDir.path, p.join(tmp.path, 'failed'));
    expect(dir.certsDir.path, p.join(tmp.path, 'certs'));
    expect(
      dir.markerDir('postgres').path,
      p.join(tmp.path, 'markers', 'postgres'),
    );
    expect(dir.markerDir('redis').path, p.join(tmp.path, 'markers', 'redis'));
  });

  group('markerDir kind validation', () {
    // kind becomes a path segment under root, so anything that could walk
    // out of the state directory — or that simply is not the plain
    // lowercase token every kind is meant to be — must be rejected here
    // rather than reaching the filesystem.
    final dir = StateDir(Directory('/does/not/matter'));

    test('rejects a kind containing ".."', () {
      expect(() => dir.markerDir('..'), throwsArgumentError);
      expect(() => dir.markerDir('../etc'), throwsArgumentError);
      expect(() => dir.markerDir('postgres/..'), throwsArgumentError);
    });

    test('rejects a kind containing a slash', () {
      expect(() => dir.markerDir('postgres/x'), throwsArgumentError);
      expect(() => dir.markerDir('/postgres'), throwsArgumentError);
    });

    test('rejects a kind with uppercase letters', () {
      expect(() => dir.markerDir('Postgres'), throwsArgumentError);
    });

    test('rejects an empty kind', () {
      expect(() => dir.markerDir(''), throwsArgumentError);
    });

    test('accepts lowercase letters, digits, underscore and hyphen', () {
      expect(() => dir.markerDir('postgres'), returnsNormally);
      expect(() => dir.markerDir('redis-cache_2'), returnsNormally);
    });
  });

  test('ensure creates the tree and is safe to call twice', () {
    final dir = StateDir(Directory(p.join(tmp.path, 'fresh')));

    dir.ensure();
    dir.ensure();

    expect(Directory(p.join(dir.root.path, 'locks')).existsSync(), isTrue);
    expect(dir.failedDir.existsSync(), isTrue);
  });
}
