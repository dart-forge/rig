@Tags(['integration'])
library;

import 'package:rig/engine.dart';
import 'package:rig/rig.dart';
import 'package:rig_postgres/rig_postgres.dart';
import 'package:test/test.dart';

/// Everything this suite makes carries this, so the teardown finds it all even
/// when a test fails halfway.
const _ownLabel = 'dev.dart-forge.rig.test.pg';

void main() {
  late DockerEngine engine;
  // Computed synchronously, not in setUpAll: the labels below are attached
  // while groups are still being declared, before any setUpAll has run.
  final runId = DateTime.now().microsecondsSinceEpoch.toString();

  setUpAll(() async {
    engine = await connectToDocker();
  });

  tearDownAll(() async {
    for (final c in await engine.listContainers(
      filters: {
        'label': ['$_ownLabel=$runId'],
      },
    )) {
      await engine.removeContainer(c.id);
    }
    await engine.close();
  });

  /// Runs SQL over TCP as the given user, which is what makes pg_hba apply.
  Future<ExecResult> overTcp(
    String containerId,
    String sql, {
    String sslMode = 'prefer',
  }) => engine.exec(containerId, [
    'psql',
    'sslmode=$sslMode host=127.0.0.1 user=test password=test dbname=test_db',
    '-tAc',
    sql,
  ]);

  Future<String> storedVerifier(String containerId) async {
    final result = await engine.exec(containerId, [
      'psql',
      '-U',
      'test',
      '-d',
      'test_db',
      '-tAc',
      "SELECT CASE WHEN rolpassword LIKE 'SCRAM%' THEN 'scram' "
          "WHEN rolpassword LIKE 'md5%' THEN 'md5' ELSE 'other' END "
          "FROM pg_authid WHERE rolname='test'",
    ]);
    return result.output.trim();
  }

  for (final auth in PgAuth.values) {
    group('${auth.name} auth', () {
      final pg = usePostgres(
        auth: auth,
        isolation: PgIsolation.none,
        lifetime: Lifetime.dedicated,
        labels: {_ownLabel: runId},
      );

      test('accepts a connection over TCP', () async {
        final result = await overTcp(pg.container.containerId, "SELECT 'ok'");

        expect(result.exitCode, 0, reason: result.output);
        expect(result.output.trim(), 'ok');
      }, timeout: const Timeout(Duration(minutes: 5)));

      test('stores the password in the form the mode requires', () async {
        // A connection succeeding is not evidence: with md5 in pg_hba and a
        // SCRAM verifier the server authenticates with SCRAM and the test
        // passes without md5 ever being used.
        final stored = await storedVerifier(pg.container.containerId);

        expect(stored, switch (auth) {
          PgAuth.md5 => 'md5',
          PgAuth.scram => 'scram',
          // Cleartext compares against whatever is stored.
          PgAuth.password => anyOf('scram', 'md5'),
        });
      }, timeout: const Timeout(Duration(minutes: 5)));
    });
  }

  group('md5 with TLS', () {
    // verboseLogs on top of tls is the combination that broke: the shell
    // wrapper joined every flag with spaces, and log_line_prefix contains
    // spaces of its own, so the container exited before it ever got here.
    final pg = usePostgres(
      auth: PgAuth.md5,
      tls: const PgTls.selfSigned(),
      verboseLogs: true,
      isolation: PgIsolation.none,
      lifetime: Lifetime.dedicated,
      labels: {_ownLabel: runId},
    );

    test('serves TLS and still authenticates with md5', () async {
      final ssl = await engine.exec(pg.container.containerId, [
        'psql',
        '-U',
        'test',
        '-d',
        'test_db',
        '-tAc',
        'SHOW ssl',
      ]);
      expect(ssl.output.trim(), 'on', reason: ssl.output);

      final required = await overTcp(
        pg.container.containerId,
        "SELECT 'tls ok'",
        sslMode: 'require',
      );
      expect(required.exitCode, 0, reason: required.output);
      expect(required.output.trim(), 'tls ok');

      expect(await storedVerifier(pg.container.containerId), 'md5');
    });

    test('verbose logging also survived the wrapper', () async {
      final statement = await engine.exec(pg.container.containerId, [
        'psql',
        '-U',
        'test',
        '-d',
        'test_db',
        '-tAc',
        'SHOW log_statement',
      ]);
      expect(statement.output.trim(), 'all', reason: statement.output);
    });
  });

  group('two suites sharing one container', () {
    final first = usePostgres(labels: {_ownLabel: runId});
    final second = usePostgres(labels: {_ownLabel: runId});

    test('get their own databases and cannot see each other tables', () async {
      expect(
        first.container.containerId,
        second.container.containerId,
        reason: 'the same request should share one container',
      );
      expect(first.database, isNot(second.database));

      final made = await engine.exec(first.container.containerId, [
        'psql',
        '-U',
        'test',
        '-d',
        first.database,
        '-tAc',
        'CREATE TABLE only_mine (id int)',
      ]);
      expect(made.exitCode, 0, reason: made.output);

      final looked = await engine.exec(second.container.containerId, [
        'psql',
        '-U',
        'test',
        '-d',
        second.database,
        '-tAc',
        "SELECT count(*) FROM information_schema.tables "
            "WHERE table_name = 'only_mine'",
      ]);
      expect(
        looked.output.trim(),
        '0',
        reason: 'a suite must not see what another suite created',
      );
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('a dedicated Postgres', () {
    final pg = usePostgres(
      lifetime: Lifetime.dedicated,
      maxConnections: 20,
      isolation: PgIsolation.none,
      labels: {_ownLabel: runId},
    );

    test('honours the connection limit it was given', () async {
      final result = await engine.exec(pg.container.containerId, [
        'psql',
        '-U',
        'test',
        '-d',
        'test_db',
        '-tAc',
        'SHOW max_connections',
      ]);

      expect(result.output.trim(), '20');
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}
