@Tags(['integration'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:rig/engine.dart';
import 'package:rig/rig.dart';
import 'package:rig_postgres/rig_postgres.dart';
import 'package:rig_postgres/src/testing.dart' show confirmAuthMode;
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
    // Only a dedicated container is this suite's own to remove. A shared one
    // this run reused might be one another run — or another suite in this
    // same run — is still holding, and the invariant this module is built on
    // is that a shared container is never removed by a suite; `rig prune`
    // is the only thing that does. Removing it here regardless of that would
    // also be unreliable in the other direction: a shared container reused
    // from an earlier run carries no `_ownLabel`, so the filter below would
    // not even find it.
    for (final c in await engine.listContainers(
      filters: {
        'label': ['$_ownLabel=$runId'],
      },
    )) {
      if (RigLabels.tryParse(c.labels)?.lifetime != Lifetime.dedicated) {
        continue;
      }
      await engine.removeContainer(c.id);
    }
    await engine.close();
  });

  /// Runs SQL over TCP as the given user, which is what makes pg_hba apply.
  ///
  /// [host] defaults to 127.0.0.1, which is what every other caller in this
  /// file wants — but initdb's own default pg_hba.conf always carries
  /// `host all all 127.0.0.1/32 trust` ahead of whatever auth method this
  /// module appends after it, so a connection to that address authenticates
  /// as `trust` no matter which password is sent. [containerSelfIp] is the
  /// override for a caller that needs the auth method itself enforced.
  Future<ExecResult> overTcp(
    String containerId,
    String sql, {
    String sslMode = 'prefer',
    String password = 'test',
    String host = '127.0.0.1',
  }) => engine.exec(containerId, [
    'psql',
    'sslmode=$sslMode host=$host user=test password=$password '
        'dbname=test_db',
    '-tAc',
    sql,
  ]);

  /// The container's own address on its Docker network, as it sees itself.
  ///
  /// Connecting here instead of to 127.0.0.1 is what makes pg_hba's
  /// `host all all all <method>` line the one that applies, rather than the
  /// `trust` line initdb always writes for the loopback address.
  Future<String> containerSelfIp(String containerId) async {
    final result = await engine.exec(containerId, ['hostname', '-i']);
    return result.output.trim().split(' ').first;
  }

  /// Sends a Postgres SSLRequest packet over [host]:[port] and returns the
  /// single byte the server answers with: `S` if it will negotiate TLS, `N`
  /// if it will not.
  ///
  /// Every other check in this file runs inside the container over the unix
  /// socket or 127.0.0.1, which never exercises `pg.host`/`pg.port` — the
  /// module's whole product — against a real daemon. This does, without
  /// needing a Postgres client library: an SSLRequest is eight bytes and its
  /// reply is one, so a bare Socket is enough to prove something real is
  /// listening on the mapped host port and that it speaks the protocol.
  Future<int> sslNegotiationByte(String host, int port) async {
    final socket = await Socket.connect(host, port);
    try {
      final packet = ByteData(8)
        ..setInt32(0, 8)
        ..setInt32(4, 80877103);
      socket.add(packet.buffer.asUint8List());
      await socket.flush();
      final reply = await socket.first;
      return reply.first;
    } finally {
      socket.destroy();
    }
  }

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
      });

      // Cleartext has nothing to assert here: confirmAuthMode re-hashes the
      // stored password for md5 and scram specifically because pg_hba would
      // otherwise say one thing and the stored verifier another, but
      // password compares the client's cleartext value against whatever is
      // already stored, in whatever form initdb happened to choose — so
      // there is no re-hashing step whose effect this could check either
      // way, and an assertion that accepted every form the verifier could
      // possibly take would not be testing anything.
      if (auth != PgAuth.password) {
        test('stores the password in the form the mode requires', () async {
          // A connection succeeding is not evidence: with md5 in pg_hba and a
          // SCRAM verifier the server authenticates with SCRAM and the test
          // passes without md5 ever being used.
          final stored = await storedVerifier(pg.container.containerId);

          expect(stored, switch (auth) {
            PgAuth.md5 => 'md5',
            PgAuth.scram => 'scram',
            PgAuth.password => throw StateError('excluded above'),
          });

          if (auth == PgAuth.scram) {
            // The check above cannot tell "we configured this" from "we got
            // lucky": initdb's own default is already SCRAM, so stored would
            // read 'scram' even if confirmAuthMode had never run for this
            // mode. Re-running the exact statements confirmAuthMode uses,
            // with a password nothing else has ever set, and then
            // authenticating with that new value, only succeeds if the
            // ALTER actually executed — no default the server ships with
            // can produce a working password it was never given. This has
            // to go through containerSelfIp rather than the usual 127.0.0.1:
            // a password that "works" only because pg_hba trusts the
            // loopback address regardless would prove nothing either.
            final selfIp = await containerSelfIp(pg.container.containerId);
            const changed = 'confirmed-not-lucky';
            await confirmAuthMode(
              engine: engine,
              containerId: pg.container.containerId,
              auth: auth,
              user: 'test',
              password: changed,
              database: 'test_db',
            );

            final withChanged = await overTcp(
              pg.container.containerId,
              "SELECT 'ok'",
              password: changed,
              host: selfIp,
            );
            expect(withChanged.exitCode, 0, reason: withChanged.output);
          }
        });
      }

      test('a real Postgres answers on the mapped host port', () async {
        // pg.host and pg.port are the module's whole product, and every
        // other assertion in this file runs inside the container instead of
        // through them.
        final answer = await sslNegotiationByte(pg.host, pg.port);
        expect(answer, 'N'.codeUnitAt(0), reason: 'no TLS was asked for');
      });
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

    test('offers TLS on the mapped host port', () async {
      final answer = await sslNegotiationByte(pg.host, pg.port);
      expect(answer, 'S'.codeUnitAt(0), reason: 'a TLS certificate was given');
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
    });
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
    });
  });
}
