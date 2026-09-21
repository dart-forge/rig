// Your test asks for a MySQL, and gets one.
//
// Run it like any other test: `dart test`. The container is created the
// first time and reused afterwards, so only the first run pays for startup.

import 'package:rig/module.dart';
import 'package:rig_mysql/rig_mysql.dart';
import 'package:test/test.dart';

void main() {
  // A database of this suite's own, inside a container other suites share.
  final my = useMySql();

  test('there is a MySQL, and it is mine', () async {
    final engine = await currentEngine();

    final result = await engine.exec(my.container.containerId, [
      'mysql',
      '-u${my.user}',
      '-p${my.password}',
      my.database,
      '-N',
      '-B',
      '-e',
      'SELECT DATABASE()',
    ]);

    expect(result.output.trim(), my.database);
  });

  // Point your own client at it instead:
  //
  //   final connection = await MyClient.connect(my.url);
  //
  // or at the parts, if the client wants them separately:
  //
  //   my.host, my.port, my.user, my.password, my.database
}
