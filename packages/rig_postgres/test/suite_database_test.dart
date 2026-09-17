import 'package:rig/engine.dart';
import 'package:rig/fake_engine.dart';
import 'package:rig_postgres/src/suite_database.dart';
import 'package:test/test.dart';

void main() {
  late FakeDockerEngine engine;
  // FakeDockerEngine.exec requires the container to be registered, so every
  // test below runs against one it created rather than a bare literal id.
  late String containerId;
  final now = DateTime.utc(2026, 9, 17, 10, 30);

  setUp(() {
    engine = FakeDockerEngine();
    containerId = engine.addContainer(labels: const {});
  });

  String sqlOf(String call) => call.split(':').skip(2).join(':');

  group('suiteDatabaseName', () {
    test('carries the project so a stray database can be traced back', () {
      final name = suiteDatabaseName(
        project: 'aim_postgres',
        now: now,
        token: 'a1b2c3d4',
      );

      expect(name, startsWith('test_'));
      expect(name, contains('aim_postgres'));
      expect(name, endsWith('a1b2c3d4'));
    });

    test('carries the creation minute, which is how stale ones are found', () {
      // Postgres does not record when a database was created, so the name has
      // to. Without it, cleaning up after a crashed suite could not tell an
      // abandoned database from one a suite created a moment ago.
      final name = suiteDatabaseName(project: 'p', now: now, token: 't');

      expect(name, contains(minuteStampOf(now)));
    });

    test('stays a legal identifier and within the 63 character limit', () {
      final name = suiteDatabaseName(
        project: 'Wildly-Long.Project Name/With Junk' * 4,
        now: now,
        token: 'a1b2c3d4',
      );

      expect(name.length, lessThanOrEqualTo(63));
      expect(name, matches(RegExp(r'^[a-z][a-z0-9_]*$')));
    });

    test('two calls a moment apart do not collide', () {
      final a = suiteDatabaseName(project: 'p', now: now, token: 'aaaaaaaa');
      final b = suiteDatabaseName(project: 'p', now: now, token: 'bbbbbbbb');

      expect(a, isNot(b));
    });
  });

  group('createSuiteDatabase', () {
    test('clones template0, not template1', () async {
      // template1 is where a person's own additions land, and a connection to
      // it makes CREATE DATABASE fail. template0 has neither problem.
      await createSuiteDatabase(
        engine: engine,
        containerId: containerId,
        user: 'test',
        adminDatabase: 'test_db',
        database: 'test_p_x',
      );

      final sql = sqlOf(engine.calls.last);
      expect(sql, contains('CREATE DATABASE test_p_x'));
      expect(sql, contains('TEMPLATE template0'));
      expect(sql, isNot(contains('template1')));
    });

    test(
      'fails loudly rather than leaving the suite on the wrong database',
      () async {
        engine.onExec = (_) =>
            const ExecResult(exitCode: 1, output: 'ERROR: permission denied');

        await expectLater(
          createSuiteDatabase(
            engine: engine,
            containerId: containerId,
            user: 'test',
            adminDatabase: 'test_db',
            database: 'test_p_x',
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('permission denied'),
            ),
          ),
        );
      },
    );
  });

  group('dropSuiteDatabase', () {
    test(
      'forces the drop so a leaked connection cannot block teardown',
      () async {
        await dropSuiteDatabase(
          engine: engine,
          containerId: containerId,
          user: 'test',
          adminDatabase: 'test_db',
          database: 'test_p_x',
        );

        expect(sqlOf(engine.calls.last), contains('DROP DATABASE'));
        expect(sqlOf(engine.calls.last), contains('WITH (FORCE)'));
      },
    );

    test('does not throw when the database is already gone', () async {
      // Teardown runs after a failure too, and a missing database is the state
      // teardown wanted.
      engine.onExec = (_) => const ExecResult(
        exitCode: 1,
        output: 'ERROR: database "test_p_x" does not exist',
      );

      await expectLater(
        dropSuiteDatabase(
          engine: engine,
          containerId: containerId,
          user: 'test',
          adminDatabase: 'test_db',
          database: 'test_p_x',
        ),
        completes,
      );
    });
  });

  group('dropStaleSuiteDatabases', () {
    test('drops only what is old and unused', () async {
      final old = suiteDatabaseName(
        project: 'p',
        now: now.subtract(const Duration(hours: 3)),
        token: 'oldoldold',
      );
      final fresh = suiteDatabaseName(
        project: 'p',
        now: now,
        token: 'freshfre',
      );
      engine.onExec = (command) {
        final sql = command.last;
        if (sql.contains('pg_database')) {
          return ExecResult(exitCode: 0, output: '$old\n$fresh\n');
        }
        return const ExecResult(exitCode: 0, output: '');
      };

      final dropped = await dropStaleSuiteDatabases(
        engine: engine,
        containerId: containerId,
        user: 'test',
        adminDatabase: 'test_db',
        now: now,
      );

      expect(dropped, [old]);
      expect(engine.calls.join('\n'), contains('DROP DATABASE $old'));
      expect(engine.calls.join('\n'), isNot(contains('DROP DATABASE $fresh')));
    });

    test('ignores a name it did not create', () async {
      engine.onExec = (command) => command.last.contains('pg_database')
          ? const ExecResult(exitCode: 0, output: 'someones_own_database\n')
          : const ExecResult(exitCode: 0, output: '');

      expect(
        await dropStaleSuiteDatabases(
          engine: engine,
          containerId: containerId,
          user: 'test',
          adminDatabase: 'test_db',
          now: now,
        ),
        isEmpty,
      );
    });

    test('asks only for databases with nobody connected', () async {
      engine.onExec = (_) => const ExecResult(exitCode: 0, output: '');

      await dropStaleSuiteDatabases(
        engine: engine,
        containerId: containerId,
        user: 'test',
        adminDatabase: 'test_db',
        now: now,
      );

      // A suite holding a lease may be between connections, so age alone is
      // not enough to call a database abandoned.
      expect(sqlOf(engine.calls.first), contains('pg_stat_activity'));
    });

    test('says nothing and does nothing when the query fails', () async {
      engine.onExec = (_) =>
          const ExecResult(exitCode: 1, output: 'ERROR: something');

      expect(
        await dropStaleSuiteDatabases(
          engine: engine,
          containerId: containerId,
          user: 'test',
          adminDatabase: 'test_db',
          now: now,
        ),
        isEmpty,
      );
    });
  });
}
