@Tags(['integration'])
library;

import 'package:rig/module.dart';
import 'package:rig_mysql/rig_mysql.dart';
import 'package:rig_mysql/src/mysql_exec.dart'
    show mysqlCommand, mysqlIdentifier;
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

    final result = await engine.exec(
      first.container.containerId,
      mysqlCommand(
        user: first.user,
        password: first.password,
        // USE, rather than a database positional argument, because
        // mysqlCommand has no argv slot for one — the statement is the only
        // thing that travels positionally.
        sql:
            'USE ${mysqlIdentifier(first.database)}; '
            'CREATE TABLE t (id INT); INSERT INTO t VALUES (1); '
            'SELECT id FROM t',
      ),
    );

    expect(result.exitCode, 0, reason: result.output);
    expect(result.output.trim(), '1');
  });

  test('one suite cannot see the other suite tables', () async {
    // Depends on the previous test having already run and created a table
    // in `first`'s database: package:test runs the tests in this file in
    // declaration order, so that table exists by the time this one checks
    // that `second` cannot see it.
    final engine = await currentEngine();

    final result = await engine.exec(
      second.container.containerId,
      mysqlCommand(
        user: second.user,
        password: second.password,
        sql: 'USE ${mysqlIdentifier(second.database)}; SHOW TABLES',
      ),
    );

    expect(result.exitCode, 0, reason: result.output);
    expect(result.output.trim(), isEmpty);
  });
}
