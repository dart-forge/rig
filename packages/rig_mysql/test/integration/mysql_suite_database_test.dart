@Tags(['integration'])
library;

import 'package:rig/module.dart';
import 'package:rig_mysql/rig_mysql.dart';
import 'package:test/test.dart';

void main() {
  final first = useMySql();
  final second = useMySql();

  test('each suite gets a database of its own', () {
    expect(first.database, isNot(second.database));
  });

  test('the test user can read and write its own database', () async {
    // MYSQL_USER holds rights on MYSQL_DATABASE and nothing else, so without
    // the grant the database would exist and be unusable. Connecting as the
    // test user rather than root is the whole point of this check.
    final engine = await currentEngine();

    final result = await engine.exec(first.container.containerId, [
      'mysql',
      '-u${first.user}',
      '-p${first.password}',
      first.database,
      '-N',
      '-B',
      '-e',
      'CREATE TABLE t (id INT); INSERT INTO t VALUES (1); SELECT id FROM t',
    ]);

    expect(result.exitCode, 0, reason: result.output);
    expect(result.output.trim(), '1');
  });

  test('one suite cannot see the other suite tables', () async {
    // Depends on the previous test having already run and created a table
    // in `first`'s database: package:test runs the tests in this file in
    // declaration order, so that table exists by the time this one checks
    // that `second` cannot see it.
    final engine = await currentEngine();

    final result = await engine.exec(second.container.containerId, [
      'mysql',
      '-u${second.user}',
      '-p${second.password}',
      second.database,
      '-N',
      '-B',
      '-e',
      'SHOW TABLES',
    ]);

    expect(result.exitCode, 0, reason: result.output);
    expect(result.output.trim(), isEmpty);
  });
}
