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

  test('lays out locks, failed markers and certs', () {
    final dir = StateDir(Directory(tmp.path));

    expect(dir.lockPath('abc123'), p.join(tmp.path, 'locks', 'abc123.lock'));
    expect(
      dir.failedMarker('cid').path,
      p.join(tmp.path, 'failed', 'cid.json'),
    );
    expect(dir.failedDir.path, p.join(tmp.path, 'failed'));
    expect(dir.certsDir.path, p.join(tmp.path, 'certs'));
  });

  test('ensure creates the tree and is safe to call twice', () {
    final dir = StateDir(Directory(p.join(tmp.path, 'fresh')));

    dir.ensure();
    dir.ensure();

    expect(Directory(p.join(dir.root.path, 'locks')).existsSync(), isTrue);
    expect(dir.failedDir.existsSync(), isTrue);
  });
}
