@Tags(['integration'])
library;

import 'package:rig/module.dart';
import 'package:rig/rig.dart';
import 'package:rig_mysql/rig_mysql.dart';
import 'package:rig_mysql/src/suite_database.dart';
import 'package:test/test.dart';

void main() {
  // Dedicated, not shared: this suite drives the sweep by calling
  // createSuiteDatabase / dropStaleSuiteDatabases / dropSuiteDatabase
  // directly, without the per-container lock useMySql() takes internally
  // around its own use of them. On a shared container, another suite's own
  // sweep (anything using the default MySqlIsolation.database) races this
  // one for the same rows and markers — confirmed by running into it: once
  // as a crash when a marker this test still believed in was deleted out
  // from under a concurrent sweep, and once as this test's own database,
  // still marked as claimed by this test's own accounting, getting reclaimed
  // anyway. A dedicated container removes the other sweeper rather than
  // trying to lock against it.
  final my = useMySql(
    isolation: MySqlIsolation.none,
    lifetime: Lifetime.dedicated,
  );

  test('reclaims an abandoned database and leaves a claimed one', () async {
    final engine = await currentEngine();
    final stateDir = StateDir.forUser();
    final now = DateTime.now().toUtc();

    final abandoned = suiteDatabaseName(
      project: 'rig_mysql_sweep',
      now: now.subtract(const Duration(hours: 3)),
      token: newSuiteToken(),
    );
    final claimed = suiteDatabaseName(
      project: 'rig_mysql_sweep',
      now: now.subtract(const Duration(hours: 3)),
      token: newSuiteToken(),
    );

    for (final database in [abandoned, claimed]) {
      await createSuiteDatabase(
        engine: engine,
        containerId: my.container.containerId,
        rootPassword: my.rootPassword,
        user: my.user,
        database: database,
        stateDir: stateDir,
      );
    }

    // createSuiteDatabase marked both. Take the abandoned one's marker away,
    // which is the state a run that died before teardown leaves behind.
    suiteMarkerFile(
      stateDir: stateDir,
      kind: 'mysql',
      containerId: my.container.containerId,
      resource: abandoned,
    ).deleteSync();

    final dropped = await dropStaleSuiteDatabases(
      engine: engine,
      containerId: my.container.containerId,
      rootPassword: my.rootPassword,
      now: now,
      stateDir: stateDir,
    );

    expect(dropped, contains(abandoned));
    expect(dropped, isNot(contains(claimed)));

    await dropSuiteDatabase(
      engine: engine,
      containerId: my.container.containerId,
      rootPassword: my.rootPassword,
      database: claimed,
      stateDir: stateDir,
    );
  });
}
