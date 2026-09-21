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

    // Two details, both of which bite if you skip them. The password goes
    // through the environment: with `-p` on the command line the client
    // writes a warning to stderr, and Docker merges stderr into stdout, so
    // the warning would land in the output next to the value. And the
    // statement travels as a positional parameter, which the shell does not
    // re-scan — pasting it into the script would turn a backtick-quoted
    // identifier into command substitution.
    final result = await engine.exec(my.container.containerId, [
      'sh',
      '-c',
      r'MYSQL_PWD="$1" exec mysql -u"$2" -N -B "$4" -e "$3"',
      'sh',
      my.password,
      my.user,
      'SELECT DATABASE()',
      my.database,
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
