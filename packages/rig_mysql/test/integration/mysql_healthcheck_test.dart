@Tags(['integration'])
library;

import 'package:rig/module.dart';
import 'package:rig_mysql/rig_mysql.dart';
import 'package:test/test.dart';

void main() {
  final my = useMySql(isolation: MySqlIsolation.none);

  test('the container became healthy at all', () async {
    // If this times out, the assumption below is the first thing to check.
    expect(my.port, greaterThan(1024));
  });

  test('mysqladmin ping exits 0 even when the login is refused', () async {
    // The healthcheck carries no credentials and leans on this. If it is
    // false, the probe never succeeds and every integration suite times out
    // 120 seconds at a time, with nothing pointing at the cause.
    final engine = await currentEngine();

    final refused = await engine.exec(my.container.containerId, [
      'mysqladmin',
      'ping',
      '-h',
      '127.0.0.1',
      '-u',
      'definitely-not-a-user',
      '-pdefinitely-not-a-password',
    ]);

    expect(
      refused.exitCode,
      0,
      reason:
          'mysqladmin ping answered ${refused.exitCode}: '
          '${refused.output}. The healthcheck in mysqlSpec has to carry '
          'credentials after all — see the alternative recorded with it.',
    );
  });
}
