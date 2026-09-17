import 'dart:async';
import 'dart:io';

import 'package:rig/fake_engine.dart';
import 'package:rig/module.dart';
import 'package:rig/rig.dart';
import 'package:rig_postgres/src/suite_database.dart';
import 'package:test/test.dart';

void main() {
  late FakeDockerEngine engine;
  // FakeDockerEngine.exec requires the container to be registered, so every
  // test below runs against one it created rather than a bare literal id.
  late String containerId;
  late Directory tmp;
  late StateDir stateDir;
  final now = DateTime.utc(2026, 9, 17, 10, 30);

  setUp(() {
    engine = FakeDockerEngine();
    containerId = engine.addContainer(labels: const {});
    tmp = Directory.systemTemp.createTempSync('rig_pg_suite_');
    stateDir = StateDir(tmp);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

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

    test('every name it generates is one it can recognise', () {
      // A generator that can emit a name its own parser rejects leaves
      // databases nobody ever cleans up, in a container that is never
      // removed. The empty and symbol-only cases are reachable:
      // currentProjectName returns an empty string when it finds no pubspec.
      const projects = [
        'aim_postgres',
        '',
        '___',
        '123',
        'a',
        'Wildly-Long.Project Name/With Junk Wildly-Long.Project Name/With Junk',
      ];

      for (final project in projects) {
        final name = suiteDatabaseName(
          project: project,
          now: now,
          token: 'a1b2c3d4',
        );

        expect(
          createdAtOf(name),
          isNotNull,
          reason:
              'generated "$name" from "$project" and could not parse '
              'it back',
        );
        expect(name.length, lessThanOrEqualTo(63));
        expect(name, matches(RegExp(r'^[a-z][a-z0-9_]*$')));
      }
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
        stateDir: stateDir,
      );

      final sql = sqlOf(engine.calls.last);
      expect(sql, contains('CREATE DATABASE test_p_x'));
      expect(sql, contains('TEMPLATE template0'));
      expect(sql, isNot(contains('template1')));
    });

    test('marks the database as belonging to a running suite', () async {
      await createSuiteDatabase(
        engine: engine,
        containerId: containerId,
        user: 'test',
        adminDatabase: 'test_db',
        database: 'test_p_x',
        stateDir: stateDir,
      );

      expect(
        suiteMarkerFile(
          stateDir: stateDir,
          containerId: containerId,
          database: 'test_p_x',
        ).existsSync(),
        isTrue,
      );
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
            stateDir: stateDir,
          ),
          throwsA(
            isA<SuiteDatabaseNotCreated>().having(
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
          stateDir: stateDir,
        );

        expect(sqlOf(engine.calls.last), contains('DROP DATABASE IF EXISTS'));
        expect(sqlOf(engine.calls.last), contains('WITH (FORCE)'));
      },
    );

    test('a sweep-driven drop does not force', () async {
      // Forcing would remove the very protection the "nobody connected"
      // check exists to give a live suite between connections.
      await dropSuiteDatabase(
        engine: engine,
        containerId: containerId,
        user: 'test',
        adminDatabase: 'test_db',
        database: 'test_p_x',
        stateDir: stateDir,
        force: false,
      );

      expect(sqlOf(engine.calls.last), contains('DROP DATABASE IF EXISTS'));
      expect(sqlOf(engine.calls.last), isNot(contains('FORCE')));
    });

    test('clears the marker along with the database', () async {
      await createSuiteDatabase(
        engine: engine,
        containerId: containerId,
        user: 'test',
        adminDatabase: 'test_db',
        database: 'test_p_x',
        stateDir: stateDir,
      );

      final marker = suiteMarkerFile(
        stateDir: stateDir,
        containerId: containerId,
        database: 'test_p_x',
      );
      expect(marker.existsSync(), isTrue);

      await dropSuiteDatabase(
        engine: engine,
        containerId: containerId,
        user: 'test',
        adminDatabase: 'test_db',
        database: 'test_p_x',
        stateDir: stateDir,
      );

      expect(marker.existsSync(), isFalse);
    });

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
          stateDir: stateDir,
        ),
        completes,
      );
    });

    test('does not throw, and leaves the marker for prune, when Docker itself '
        'could not run the drop', () async {
      // A container that vanished between the lease resolving and
      // tearDownAll reaching psql (rig prune, a Docker restart) must not
      // turn a passing suite red in teardown.
      await createSuiteDatabase(
        engine: engine,
        containerId: containerId,
        user: 'test',
        adminDatabase: 'test_db',
        database: 'test_p_x',
        stateDir: stateDir,
      );
      final marker = suiteMarkerFile(
        stateDir: stateDir,
        containerId: containerId,
        database: 'test_p_x',
      );
      expect(marker.existsSync(), isTrue);

      engine.onExec = (_) => throw EngineError(
        method: 'POST',
        path: '/containers/$containerId/exec',
        statusCode: 404,
        body: 'No such container',
      );

      final lines = <String>[];
      await runZoned(
        () => dropSuiteDatabase(
          engine: engine,
          containerId: containerId,
          user: 'test',
          adminDatabase: 'test_db',
          database: 'test_p_x',
          stateDir: stateDir,
        ),
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => lines.add(line),
        ),
      );

      expect(lines, hasLength(1));
      expect(lines.single, allOf(contains('test_p_x'), contains(containerId)));
      expect(
        marker.existsSync(),
        isTrue,
        reason:
            'the container is gone, so nothing here can tell whether the '
            'database went with it; rig prune reclaims this marker',
      );
    });
  });

  group('dropStaleSuiteDatabases', () {
    test('drops only what is old and unused', () async {
      // Tokens are hex because that is what newSuiteToken produces, and the
      // parser only accepts names this module could have written.
      final old = suiteDatabaseName(
        project: 'p',
        now: now.subtract(const Duration(hours: 3)),
        token: 'deadbeef',
      );
      final fresh = suiteDatabaseName(
        project: 'p',
        now: now.subtract(const Duration(minutes: 5)),
        token: 'cafebabe',
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
        stateDir: stateDir,
      );

      expect(dropped, [old]);
      expect(engine.calls.join('\n'), contains('DROP DATABASE IF EXISTS $old'));
      expect(
        engine.calls.join('\n'),
        isNot(contains('DROP DATABASE IF EXISTS $fresh')),
      );
    });

    test('never forces the drop it makes on someone else\'s behalf', () async {
      final old = suiteDatabaseName(
        project: 'p',
        now: now.subtract(const Duration(hours: 3)),
        token: 'deadbeef',
      );
      engine.onExec = (command) => command.last.contains('pg_database')
          ? ExecResult(exitCode: 0, output: '$old\n')
          : const ExecResult(exitCode: 0, output: '');

      await dropStaleSuiteDatabases(
        engine: engine,
        containerId: containerId,
        user: 'test',
        adminDatabase: 'test_db',
        now: now,
        stateDir: stateDir,
      );

      expect(
        engine.calls.join('\n'),
        isNot(contains('FORCE')),
        reason:
            'forcing here would remove the protection the pg_stat_activity '
            'check exists to give a live suite between connections',
      );
    });

    test('keeps a database created just before a minute boundary', () async {
      // The stamp is floored, so this database claims to be a minute older
      // than it is. Judged by the stamp alone it would be dropped before its
      // own suite ever connected.
      final justMade = suiteDatabaseName(
        project: 'p',
        now: now.subtract(const Duration(seconds: 59)),
        token: 'abcdabcd',
      );
      engine.onExec = (command) => command.last.contains('pg_database')
          ? ExecResult(exitCode: 0, output: '$justMade\n')
          : const ExecResult(exitCode: 0, output: '');

      final dropped = await dropStaleSuiteDatabases(
        engine: engine,
        containerId: containerId,
        user: 'test',
        adminDatabase: 'test_db',
        now: now,
        stateDir: stateDir,
        staleAfter: const Duration(seconds: 30),
      );

      expect(dropped, isEmpty);
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
          stateDir: stateDir,
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
        stateDir: stateDir,
      );

      // A suite holding a lease may be between connections, so age alone is
      // not enough to call a database abandoned.
      expect(sqlOf(engine.calls.first), contains('pg_stat_activity'));
    });

    test('a marked database with a fresh marker survives a sweep that would '
        'otherwise drop it', () async {
      // Old enough, and nobody is connected to it right now — by the age
      // and connection rules alone this would be condemned. Only the
      // marker, which createSuiteDatabase writes and only teardown
      // removes, says a suite still claims it.
      final claimed = suiteDatabaseName(
        project: 'p',
        now: now.subtract(const Duration(hours: 3)),
        token: 'deadbeef',
      );
      final marker = suiteMarkerFile(
        stateDir: stateDir,
        containerId: containerId,
        database: claimed,
      );
      marker.parent.createSync(recursive: true);
      marker.writeAsStringSync('');
      // Explicit rather than relying on the marker having just been
      // written at real wall-clock time: this pins "fresh" to the fixed
      // `now` this test already reasons about everywhere else.
      marker.setLastModifiedSync(now.subtract(const Duration(minutes: 1)));

      engine.onExec = (command) => command.last.contains('pg_database')
          ? ExecResult(exitCode: 0, output: '$claimed\n')
          : const ExecResult(exitCode: 0, output: '');

      final dropped = await dropStaleSuiteDatabases(
        engine: engine,
        containerId: containerId,
        user: 'test',
        adminDatabase: 'test_db',
        now: now,
        stateDir: stateDir,
      );

      expect(dropped, isEmpty);
      expect(engine.calls.join('\n'), isNot(contains('DROP DATABASE')));
      expect(
        marker.existsSync(),
        isTrue,
        reason: 'a marker that still protects its database must survive',
      );
    });

    test('a database whose marker is older than markerStaleAfter is dropped, '
        'and the marker goes with it', () async {
      // Without this, the sweep could never reclaim anything at all: a
      // database whose teardown ran was already dropped by that same
      // teardown, so every database the sweep ever meets either never had
      // a marker or still carries one from a suite that did not reach
      // teardown. The marker's own age is what tells that suite apart
      // from one merely between connections.
      final abandoned = suiteDatabaseName(
        project: 'p',
        now: now.subtract(const Duration(hours: 3)),
        token: 'deadbeef',
      );
      final marker = suiteMarkerFile(
        stateDir: stateDir,
        containerId: containerId,
        database: abandoned,
      );
      marker.parent.createSync(recursive: true);
      marker.writeAsStringSync('');
      marker.setLastModifiedSync(
        now.subtract(const Duration(hours: 25)),
      ); // older than the 24-hour default

      engine.onExec = (command) => command.last.contains('pg_database')
          ? ExecResult(exitCode: 0, output: '$abandoned\n')
          : const ExecResult(exitCode: 0, output: '');

      final dropped = await dropStaleSuiteDatabases(
        engine: engine,
        containerId: containerId,
        user: 'test',
        adminDatabase: 'test_db',
        now: now,
        stateDir: stateDir,
      );

      expect(dropped, [abandoned]);
      expect(
        engine.calls.join('\n'),
        contains('DROP DATABASE IF EXISTS $abandoned'),
      );
      expect(
        marker.existsSync(),
        isFalse,
        reason: 'a marker that no longer protects anything must not linger',
      );
    });

    test('a marker aged between the two thresholds still protects its '
        'database, so the thresholds are not collapsed into one', () async {
      // The database is old enough to be dropped by staleAfter (an hour,
      // by default) on its own. Its marker is older than that same
      // staleAfter but younger than markerStaleAfter (a day). If the
      // marker check compared against staleAfter instead of its own
      // threshold, this marker would be wrongly judged expired.
      final claimed = suiteDatabaseName(
        project: 'p',
        now: now.subtract(const Duration(hours: 3)),
        token: 'deadbeef',
      );
      final marker = suiteMarkerFile(
        stateDir: stateDir,
        containerId: containerId,
        database: claimed,
      );
      marker.parent.createSync(recursive: true);
      marker.writeAsStringSync('');
      // Older than the default staleAfter (1 hour), younger than the
      // default markerStaleAfter (24 hours).
      marker.setLastModifiedSync(now.subtract(const Duration(hours: 2)));

      engine.onExec = (command) => command.last.contains('pg_database')
          ? ExecResult(exitCode: 0, output: '$claimed\n')
          : const ExecResult(exitCode: 0, output: '');

      final dropped = await dropStaleSuiteDatabases(
        engine: engine,
        containerId: containerId,
        user: 'test',
        adminDatabase: 'test_db',
        now: now,
        stateDir: stateDir,
      );

      expect(dropped, isEmpty);
      expect(engine.calls.join('\n'), isNot(contains('DROP DATABASE')));
    });

    test('does not report a drop that did not happen, and leaves the marker '
        'and the database alone', () async {
      // force: false means a backend connecting between the listing and
      // this statement is the expected way for the drop to fail — it is
      // exactly the protection that WITH (FORCE) being off the sweep path
      // exists to give. The sweep must not tell the world it dropped a
      // database that is still there.
      final claimed = suiteDatabaseName(
        project: 'p',
        now: now.subtract(const Duration(hours: 3)),
        token: 'deadbeef',
      );
      final marker = suiteMarkerFile(
        stateDir: stateDir,
        containerId: containerId,
        database: claimed,
      );
      marker.parent.createSync(recursive: true);
      marker.writeAsStringSync('');
      marker.setLastModifiedSync(now.subtract(const Duration(hours: 25)));

      engine.onExec = (command) {
        final sql = command.last;
        if (sql.contains('pg_database')) {
          return ExecResult(exitCode: 0, output: '$claimed\n');
        }
        if (sql.contains('DROP DATABASE')) {
          return ExecResult(
            exitCode: 1,
            output:
                'ERROR: database "$claimed" is being accessed by other '
                'users',
          );
        }
        return const ExecResult(exitCode: 0, output: '');
      };

      final lines = <String>[];
      final dropped = await runZoned(
        () => dropStaleSuiteDatabases(
          engine: engine,
          containerId: containerId,
          user: 'test',
          adminDatabase: 'test_db',
          now: now,
          stateDir: stateDir,
        ),
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => lines.add(line),
        ),
      );

      expect(
        dropped,
        isEmpty,
        reason: 'the drop did not succeed, so nothing was actually dropped',
      );
      expect(
        lines.any((l) => l.contains('dropped')),
        isFalse,
        reason: 'must not claim a drop that did not happen',
      );
      expect(
        lines.any(
          (l) =>
              l.contains(claimed) &&
              l.contains('skipped') &&
              l.contains('accessed by other users'),
        ),
        isTrue,
        reason:
            'must name the database, say it was skipped, and say why psql '
            'reported',
      );
      expect(
        marker.existsSync(),
        isTrue,
        reason: 'a marker for a database that was not dropped must stay',
      );
    });

    test(
      'does nothing when the query fails, but says which container',
      () async {
        engine.onExec = (_) =>
            const ExecResult(exitCode: 1, output: 'ERROR: something');

        final lines = <String>[];
        final dropped = await runZoned(
          () => dropStaleSuiteDatabases(
            engine: engine,
            containerId: containerId,
            user: 'test',
            adminDatabase: 'test_db',
            now: now,
            stateDir: stateDir,
          ),
          zoneSpecification: ZoneSpecification(
            print: (self, parent, zone, line) => lines.add(line),
          ),
        );

        expect(dropped, isEmpty);
        expect(lines, hasLength(1));
        expect(lines.single, contains(containerId));
      },
    );

    test('catches the engine failing to run the listing, and says so, rather '
        'than throwing', () async {
      // engine.exec raises EngineError for any Docker status >= 400 — a
      // container removed by `rig prune` or a Docker restart between the
      // lease resolving and this running is reachable, and a broken sweep
      // must not fail the suite that happens to trigger it.
      engine.onExec = (_) => throw EngineError(
        method: 'POST',
        path: '/containers/$containerId/exec',
        statusCode: 404,
        body: 'No such container',
      );

      final lines = <String>[];
      final dropped = await runZoned(
        () => dropStaleSuiteDatabases(
          engine: engine,
          containerId: containerId,
          user: 'test',
          adminDatabase: 'test_db',
          now: now,
          stateDir: stateDir,
        ),
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => lines.add(line),
        ),
      );

      expect(dropped, isEmpty);
      expect(lines, hasLength(1));
      expect(lines.single, contains(containerId));
    });

    test(
      'a bug in this file is not swallowed the way an engine failure is',
      () async {
        // Catching Object here would also catch this file's own mistakes,
        // which is not what the sweep being forgiving is for.
        engine.onExec = (_) => throw StateError('not an engine failure');

        await expectLater(
          dropStaleSuiteDatabases(
            engine: engine,
            containerId: containerId,
            user: 'test',
            adminDatabase: 'test_db',
            now: now,
            stateDir: stateDir,
          ),
          throwsA(isA<StateError>()),
        );
      },
    );

    test('returns what it already dropped when the engine fails partway '
        'through the sweep', () async {
      final first = suiteDatabaseName(
        project: 'p',
        now: now.subtract(const Duration(hours: 3)),
        token: 'aaaaaaaa',
      );
      final second = suiteDatabaseName(
        project: 'p',
        now: now.subtract(const Duration(hours: 3)),
        token: 'bbbbbbbb',
      );
      engine.onExec = (command) {
        final sql = command.last;
        if (sql.contains('pg_database')) {
          return ExecResult(exitCode: 0, output: '$first\n$second\n');
        }
        if (sql.contains('DROP DATABASE IF EXISTS $first')) {
          return const ExecResult(exitCode: 0, output: '');
        }
        throw EngineError(
          method: 'POST',
          path: '/containers/$containerId/exec',
          statusCode: 404,
          body: 'No such container',
        );
      };

      final dropped = await dropStaleSuiteDatabases(
        engine: engine,
        containerId: containerId,
        user: 'test',
        adminDatabase: 'test_db',
        now: now,
        stateDir: stateDir,
      );

      expect(dropped, [first]);
    });

    test('says which database it dropped and from which container', () async {
      final old = suiteDatabaseName(
        project: 'p',
        now: now.subtract(const Duration(hours: 3)),
        token: 'deadbeef',
      );
      engine.onExec = (command) => command.last.contains('pg_database')
          ? ExecResult(exitCode: 0, output: '$old\n')
          : const ExecResult(exitCode: 0, output: '');

      final lines = <String>[];
      await runZoned(
        () => dropStaleSuiteDatabases(
          engine: engine,
          containerId: containerId,
          user: 'test',
          adminDatabase: 'test_db',
          now: now,
          stateDir: stateDir,
        ),
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => lines.add(line),
        ),
      );

      expect(lines, hasLength(1));
      expect(lines.single, allOf(contains(old), contains(containerId)));
    });
  });
}
