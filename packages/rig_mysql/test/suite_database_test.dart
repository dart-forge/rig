import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rig/fake_engine.dart';
import 'package:rig/module.dart';
import 'package:rig/rig.dart';
import 'package:rig_mysql/src/suite_database.dart';
import 'package:test/test.dart';

void main() {
  late FakeDockerEngine engine;
  // FakeDockerEngine.exec requires the container to be registered, so every
  // test below runs against one it created rather than a bare literal id.
  late String containerId;
  late Directory tmp;
  late StateDir stateDir;
  final now = DateTime.utc(2026, 9, 21, 10, 30);

  setUp(() {
    engine = FakeDockerEngine();
    containerId = engine.addContainer(labels: const {});
    tmp = Directory.systemTemp.createTempSync('rig_my_suite_');
    stateDir = StateDir(tmp);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  List<String> statements() => [
    for (final call in engine.calls)
      if (call.startsWith('exec:')) call.split('-e ').last,
  ];

  File markerFor(String database) => suiteMarkerFile(
    stateDir: stateDir,
    kind: 'mysql',
    containerId: containerId,
    resource: database,
  );

  String named({required Duration ago}) => suiteDatabaseName(
    project: 'p',
    now: now.subtract(ago),
    token: 'deadbeef',
  );

  group('createSuiteDatabase', () {
    Future<void> create({String database = 'test_p_1_deadbeef'}) =>
        createSuiteDatabase(
          engine: engine,
          containerId: containerId,
          rootPassword: 'root',
          user: 'test',
          database: database,
          stateDir: stateDir,
        );

    test('creates the database and grants the test user on it', () async {
      // MYSQL_USER only has rights on MYSQL_DATABASE, so without the grant
      // the suite's own database would exist and be unusable.
      await create();

      expect(statements().single, contains('CREATE DATABASE'));
      expect(statements().single, contains('GRANT ALL PRIVILEGES'));
    });

    test('quotes the database name and the user the way MySQL wants', () async {
      await create();

      expect(statements().single, contains('`test_p_1_deadbeef`'));
      expect(statements().single, contains("'test'@'%'"));
    });

    test('marks the database as belonging to a running suite', () async {
      await create();

      expect(markerFor('test_p_1_deadbeef').existsSync(), isTrue);
    });

    test('throws when the server refused', () async {
      engine.onExec = (_) =>
          const ExecResult(exitCode: 1, output: 'ERROR 1007 (HY000)');

      await expectLater(create(), throwsA(isA<SuiteDatabaseNotCreated>()));
    });

    test('does not leave a marker behind when the create failed', () async {
      engine.onExec = (_) =>
          const ExecResult(exitCode: 1, output: 'ERROR 1007 (HY000)');

      await expectLater(create(), throwsA(isA<SuiteDatabaseNotCreated>()));
      expect(markerFor('test_p_1_deadbeef').existsSync(), isFalse);
    });

    test('drops the database it just made when the marker cannot be '
        'written', () async {
      // MySQL's DROP DATABASE succeeds even with something connected, so the
      // marker is the only thing between a live suite and the sweep. A
      // database without one would be reclaimed under a running suite, so
      // arriving at that state is worth failing over — and the database has
      // to go with it rather than leak.
      // A file where the marker directory would go, rather than making tmp
      // itself a file: tearDown deletes tmp as a directory, and a recursive
      // directory delete against a file path throws, which would turn this
      // test's failure into a confusing teardown error.
      final blocked = File(p.join(tmp.path, 'blocked'))
        ..writeAsStringSync('not a directory');
      final blockedStateDir = StateDir(Directory(blocked.path));

      await expectLater(
        createSuiteDatabase(
          engine: engine,
          containerId: containerId,
          rootPassword: 'root',
          user: 'test',
          database: 'test_p_1_deadbeef',
          stateDir: blockedStateDir,
        ),
        throwsA(isA<SuiteMarkerNotWritten>()),
      );
      expect(statements().last, contains('DROP DATABASE'));
    });
  });

  group('dropSuiteDatabase', () {
    Future<void> drop({String database = 'test_p_1_deadbeef'}) =>
        dropSuiteDatabase(
          engine: engine,
          containerId: containerId,
          rootPassword: 'root',
          database: database,
          stateDir: stateDir,
        );

    test('drops the database', () async {
      await drop();

      expect(statements().single, contains('DROP DATABASE IF EXISTS'));
    });

    test('does not try to force anything', () async {
      // Postgres needs WITH (FORCE) to drop a database someone is connected
      // to. MySQL drops it either way, so there is no such clause and
      // nothing to ask for.
      await drop();

      expect(statements().single, isNot(contains('FORCE')));
    });

    test('clears the marker along with the database', () async {
      final marker = markerFor('test_p_1_deadbeef');
      marker.parent.createSync(recursive: true);
      marker.writeAsStringSync('');

      await drop();

      expect(marker.existsSync(), isFalse);
    });

    test('does not throw when the database is already gone', () async {
      // Teardown runs after a failure too, and a database that is already
      // gone is the state teardown was asking for.
      engine.onExec = (_) =>
          const ExecResult(exitCode: 1, output: 'ERROR 1008 (HY000)');

      await expectLater(drop(), completes);
    });

    test('leaves the marker for prune when Docker itself failed', () async {
      // The container is gone, so nothing here can tell whether its database
      // went with it. rig prune reclaims a marker directory once its
      // container is no longer known to the daemon.
      final marker = markerFor('test_p_1_deadbeef');
      marker.parent.createSync(recursive: true);
      marker.writeAsStringSync('');
      engine.onExec = (_) => throw const EngineError(
        method: 'POST',
        path: '/exec',
        statusCode: 404,
        body: 'no such container',
      );

      await expectLater(drop(), completes);
      expect(marker.existsSync(), isTrue);
    });
  });

  group('dropStaleSuiteDatabases', () {
    Future<List<String>> sweep() => dropStaleSuiteDatabases(
      engine: engine,
      containerId: containerId,
      rootPassword: 'root',
      now: now,
      stateDir: stateDir,
    );

    void answerListing(List<String> databases) {
      engine.onExec = (command) {
        final sql = command.last;
        if (sql.contains('information_schema')) {
          return ExecResult(exitCode: 0, output: databases.join('\n'));
        }
        return const ExecResult(exitCode: 0, output: '');
      };
    }

    test('asks only for databases with nobody connected', () async {
      answerListing(const []);

      await sweep();

      expect(statements().first, contains('information_schema.SCHEMATA'));
      expect(statements().first, contains('information_schema.PROCESSLIST'));
      expect(statements().first, contains('NOT EXISTS'));
    });

    test('drops what is old and unclaimed', () async {
      final old = named(ago: const Duration(hours: 3));
      answerListing([old]);

      expect(await sweep(), [old]);
      expect(statements().last, contains('DROP DATABASE IF EXISTS'));
    });

    test('leaves a young database alone', () async {
      answerListing([named(ago: const Duration(minutes: 5))]);

      expect(await sweep(), isEmpty);
    });

    test('ignores a name it did not create', () async {
      answerListing(const ['test_someones_own_thing']);

      expect(await sweep(), isEmpty);
    });

    test('leaves a database a running suite still claims', () async {
      final claimed = named(ago: const Duration(days: 30));
      final marker = markerFor(claimed);
      marker.parent.createSync(recursive: true);
      marker.writeAsStringSync('');
      marker.setLastModifiedSync(now.subtract(const Duration(minutes: 5)));
      answerListing([claimed]);

      expect(await sweep(), isEmpty);
    });

    test(
      'catches the engine failing to run the listing, and says so',
      () async {
        // A shared container's data directory is a tmpfs. A sweep that
        // silently never runs lets suite databases pile up in RAM until the
        // container cannot write, which surfaces weeks later as "No space left
        // on device" in some unrelated suite. Nothing about it is worth failing
        // this run over, so it prints and carries on.
        engine.onExec = (_) => throw const EngineError(
          method: 'POST',
          path: '/exec',
          statusCode: 404,
          body: 'no such container',
        );

        expect(await sweep(), isEmpty);
      },
    );

    test('does not report a drop that did not happen', () async {
      final old = named(ago: const Duration(hours: 3));
      engine.onExec = (command) {
        final sql = command.last;
        if (sql.contains('information_schema')) {
          return ExecResult(exitCode: 0, output: old);
        }
        return const ExecResult(exitCode: 1, output: 'ERROR 1010 (HY000)');
      };

      expect(await sweep(), isEmpty);
      expect(markerFor(old).existsSync(), isFalse);
    });
  });
}
