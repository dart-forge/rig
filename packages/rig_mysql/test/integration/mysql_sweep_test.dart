@Tags(['integration'])
library;

import 'package:rig/module.dart';
import 'package:rig/rig.dart';
import 'package:rig_mysql/rig_mysql.dart';
import 'package:rig_mysql/src/suite_database.dart';
import 'package:test/test.dart';

void main() {
  final my = useMySql(isolation: MySqlIsolation.none);

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
