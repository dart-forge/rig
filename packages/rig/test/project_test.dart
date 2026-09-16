import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rig/src/project.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('rig_project_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  void writePubspec(String dir, String name) {
    File(p.join(tmp.path, dir, 'pubspec.yaml'))
      ..createSync(recursive: true)
      ..writeAsStringSync('name: $name\nversion: 1.0.0\n');
  }

  test('reads the name from the nearest pubspec', () {
    writePubspec('pkg', 'aim_postgres');

    expect(
      currentProjectName(from: Directory(p.join(tmp.path, 'pkg'))),
      'aim_postgres',
    );
  });

  test('walks up from a subdirectory', () {
    writePubspec('pkg', 'aim_postgres');
    Directory(p.join(tmp.path, 'pkg', 'test', 'integration'))
        .createSync(recursive: true);

    expect(
      currentProjectName(
        from: Directory(p.join(tmp.path, 'pkg', 'test', 'integration')),
      ),
      'aim_postgres',
    );
  });

  test('takes the nearest one when nested packages exist', () {
    writePubspec('.', 'workspace_root');
    writePubspec('packages/inner', 'inner_pkg');

    expect(
      currentProjectName(
        from: Directory(p.join(tmp.path, 'packages', 'inner')),
      ),
      'inner_pkg',
    );
  });

  test('is empty rather than throwing when there is no pubspec', () {
    expect(currentProjectName(from: Directory(tmp.path)), isEmpty);
  });

  test('ignores a name that appears elsewhere in the file', () {
    File(p.join(tmp.path, 'pubspec.yaml')).writeAsStringSync(
      'dependencies:\n  foo:\n    name: not_the_package\nname: real_name\n',
    );

    expect(currentProjectName(from: Directory(tmp.path)), 'real_name');
  });
}
