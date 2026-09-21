import 'dart:io';

import 'package:rig/module.dart';
import 'package:rig/rig.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 21, 12);

  group('suiteDatabaseName', () {
    test('carries the project, the minute and the token', () {
      final name = suiteDatabaseName(
        project: 'aim_mysql',
        now: now,
        token: 'deadbeef',
      );

      expect(name, 'test_aim_mysql_${minuteStampOf(now)}_deadbeef');
    });

    test('reads back the minute it was created in', () {
      final name = suiteDatabaseName(
        project: 'aim_mysql',
        now: now,
        token: 'deadbeef',
      );

      expect(createdAtOf(name), now);
    });

    test('floors to the minute, so the stamp loses the seconds', () {
      final withSeconds = DateTime.utc(2026, 9, 21, 12, 0, 59);

      expect(
        createdAtOf(
          suiteDatabaseName(project: 'p', now: withSeconds, token: 'aaaaaaaa'),
        ),
        DateTime.utc(2026, 9, 21, 12),
      );
    });

    test('fits inside an identifier even when the project is long', () {
      final name = suiteDatabaseName(
        project: 'a' * 200,
        now: now,
        token: 'deadbeef',
      );

      // 63 is Postgres's cap; MySQL's is 64, so one number serves both.
      expect(name.length, lessThanOrEqualTo(63));
      expect(createdAtOf(name), now, reason: 'a trimmed name must still parse');
    });

    test(
      'is always a legal SQL identifier, whatever the project is called',
      () {
        // The name is interpolated into CREATE DATABASE and DROP DATABASE
        // unescaped, so a character _slugOf let through would be a syntax
        // error at best. And the sweep recognises its own databases by
        // parsing the name, so a name that came out malformed would be
        // skipped forever, in a container that is deliberately never removed.
        const projects = [
          'aim_mysql',
          '',
          '___',
          '123',
          'a',
          'Weird Name!! (v2) / mixed 漢字',
        ];

        for (final project in projects) {
          final name = suiteDatabaseName(
            project: project,
            now: now,
            token: 'deadbeef',
          );

          expect(
            name,
            matches(RegExp(r'^[a-z][a-z0-9_]*$')),
            reason: 'project: "$project"',
          );
          expect(createdAtOf(name), now, reason: 'project: "$project"');
        }
      },
    );

    test('a project that slugs away to nothing still produces a name the '
        'sweep can parse', () {
      // currentProjectName returns an empty string when it finds no pubspec,
      // and a three-part name would be skipped by the sweep forever, in a
      // container that is deliberately never removed.
      final name = suiteDatabaseName(
        project: '///',
        now: now,
        token: 'abcd1234',
      );

      expect(name, contains('unnamed'));
      expect(createdAtOf(name), now);
    });

    test('two suites in the same minute get different names', () {
      expect(
        suiteDatabaseName(project: 'p', now: now, token: 'aaaaaaaa'),
        isNot(suiteDatabaseName(project: 'p', now: now, token: 'bbbbbbbb')),
      );
    });
  });

  group('newSuiteToken', () {
    test('is eight hex characters, which is what createdAtOf expects', () {
      for (var i = 0; i < 50; i++) {
        expect(newSuiteToken(), matches(r'^[0-9a-f]{8}$'));
      }
    });
  });

  group('createdAtOf', () {
    test('refuses a name this module did not produce', () {
      expect(createdAtOf('my_own_database'), isNull);
      expect(createdAtOf('test_p_notaminute_deadbeef'), isNull);
      expect(createdAtOf('test_p_1'), isNull, reason: 'three parts, not four');
      expect(
        createdAtOf('test_p_1_DEADBEEF'),
        isNull,
        reason: 'token is lower',
      );
    });
  });

  group('isReclaimableSuiteDatabase', () {
    late Directory tmp;
    late StateDir stateDir;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('rig-naming-');
      stateDir = StateDir(tmp);
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    File markerFor(String database, {Duration? age}) {
      final marker = suiteMarkerFile(
        stateDir: stateDir,
        kind: 'postgres',
        containerId: 'abc123',
        resource: database,
      );
      if (age == null) return marker;
      marker.parent.createSync(recursive: true);
      marker.writeAsStringSync('');
      marker.setLastModifiedSync(now.subtract(age));
      return marker;
    }

    String named({required Duration ago}) => suiteDatabaseName(
      project: 'p',
      now: now.subtract(ago),
      token: 'deadbeef',
    );

    test('leaves a database this module did not create alone', () {
      expect(
        isReclaimableSuiteDatabase(
          database: 'someones_own_db',
          now: now,
          marker: markerFor('someones_own_db'),
        ),
        isFalse,
      );
    });

    test('leaves a young database alone', () {
      final db = named(ago: const Duration(minutes: 5));

      expect(
        isReclaimableSuiteDatabase(
          database: db,
          now: now,
          marker: markerFor(db),
        ),
        isFalse,
      );
    });

    test('judges age by the latest moment the name allows', () {
      // The stamp is the minute the database was created in, floored, so the
      // database can be up to a minute younger than its name claims. A
      // database whose name says exactly staleAfter ago could have been
      // created a minute later than that, which is inside the window.
      final db = named(ago: const Duration(hours: 1));

      expect(
        isReclaimableSuiteDatabase(
          database: db,
          now: now,
          marker: markerFor(db),
        ),
        isFalse,
      );
    });

    test('reclaims an old database nobody marked', () {
      final db = named(ago: const Duration(hours: 3));

      expect(
        isReclaimableSuiteDatabase(
          database: db,
          now: now,
          marker: markerFor(db),
        ),
        isTrue,
      );
    });

    test('a fresh marker protects a database however old it is', () {
      final db = named(ago: const Duration(days: 30));

      expect(
        isReclaimableSuiteDatabase(
          database: db,
          now: now,
          marker: markerFor(db, age: const Duration(minutes: 5)),
        ),
        isFalse,
      );
    });

    test('a marker older than a run could last stops protecting it', () {
      final db = named(ago: const Duration(days: 30));

      expect(
        isReclaimableSuiteDatabase(
          database: db,
          now: now,
          marker: markerFor(db, age: const Duration(days: 2)),
        ),
        isTrue,
      );
    });

    test('honours caller-supplied thresholds', () {
      final db = named(ago: const Duration(minutes: 5));

      expect(
        isReclaimableSuiteDatabase(
          database: db,
          now: now,
          marker: markerFor(db),
          staleAfter: const Duration(minutes: 1),
        ),
        isTrue,
      );
    });
  });
}
