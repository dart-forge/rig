import 'dart:io';

import 'package:rig/engine.dart';
import 'package:rig/fake_engine.dart';
import 'package:rig/rig.dart';
import 'package:rig_postgres/rig_postgres.dart';
import 'package:rig_postgres/src/testing.dart' show confirmAuthMode;
import 'package:test/test.dart';

final engine = FakeDockerEngine();
final tmp = Directory.systemTemp.createTempSync('rig_pg_');

void main() {
  overrideEngine(engine);
  tearDownAll(() => tmp.deleteSync(recursive: true));

  group('a shared Postgres', () {
    final pg = usePostgres(
      stateDir: StateDir(tmp),
      isolation: PgIsolation.none,
    );

    test('is reachable by the time a test body runs', () {
      expect(pg.port, greaterThan(1024));
      expect(pg.url, startsWith('postgresql://test:test@127.0.0.1:'));
      expect(pg.database, 'test_db');
    });
  });

  group('md5 confirms the stored password', () {
    final pg = usePostgres(
      auth: PgAuth.md5,
      stateDir: StateDir(tmp),
      isolation: PgIsolation.none,
    );

    test('re-hashes the password so the auth mode is the one asked for', () {
      // Without this the server would quietly fall back to SCRAM and the
      // container would never exercise md5 at all.
      expect(
        engine.calls.where((c) => c.contains('password_encryption')),
        isNotEmpty,
      );
      expect(pg.url, isNotEmpty);
    });
  });

  group('two suites on one container', () {
    final first = usePostgres(stateDir: StateDir(tmp));
    final second = usePostgres(stateDir: StateDir(tmp));

    test('each get their own database', () {
      expect(first.database, isNot(second.database));
      expect(first.database, startsWith('test_'));
      expect(second.database, startsWith('test_'));
    });

    test('and the same container', () {
      expect(first.container.containerId, second.container.containerId);
    });
  });

  group('isolation can be turned off', () {
    final pg = usePostgres(
      stateDir: StateDir(tmp),
      isolation: PgIsolation.none,
    );

    test('and then the container own database is used', () {
      expect(pg.database, 'test_db');
    });
  });

  group('confirmAuthMode quotes what it substitutes into SQL', () {
    test(
      'a password containing a quote does not break the statement',
      () async {
        final fake = FakeDockerEngine();
        final containerId = fake.addContainer(labels: const {});

        await confirmAuthMode(
          engine: fake,
          containerId: containerId,
          auth: PgAuth.md5,
          user: 'test',
          password: "it's",
          database: 'test_db',
        );

        final alter = fake.calls.firstWhere((c) => c.contains('ALTER USER'));
        // Unescaped, this would reach the server as `PASSWORD 'it's'` — a
        // syntax error the server reports as an unrecognised role option,
        // pointing at the wrong cause entirely.
        expect(alter, contains("PASSWORD 'it''s'"));
      },
    );

    test(
      'a user containing a double quote is quoted as an identifier',
      () async {
        final fake = FakeDockerEngine();
        final containerId = fake.addContainer(labels: const {});

        await confirmAuthMode(
          engine: fake,
          containerId: containerId,
          auth: PgAuth.md5,
          user: 'te"st',
          password: 'hunter2',
          database: 'test_db',
        );

        final alter = fake.calls.firstWhere((c) => c.contains('ALTER USER'));
        expect(alter, contains('ALTER USER "te""st"'));
      },
    );
  });
}
