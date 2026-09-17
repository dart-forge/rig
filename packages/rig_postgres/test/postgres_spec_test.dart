import 'package:rig/engine.dart';
import 'package:rig/rig.dart';
import 'package:rig_postgres/rig_postgres.dart';
import 'package:test/test.dart';

String specHashOf(ContainerSpec s) => specHash(s);

void main() {
  test('runs the version asked for', () {
    expect(postgresSpec(version: '15-alpine').image, 'postgres:15-alpine');
    expect(postgresSpec().image, 'postgres:16-alpine');
  });

  test('carries the credentials as the official image expects them', () {
    final spec = postgresSpec(
      user: 'alice',
      password: 'hunter2',
      database: 'shop',
    );

    expect(spec.env['POSTGRES_USER'], 'alice');
    expect(spec.env['POSTGRES_PASSWORD'], 'hunter2');
    expect(spec.env['POSTGRES_DB'], 'shop');
  });

  test('publishes the Postgres port', () {
    expect(postgresSpec().exposedPorts, [5432]);
  });

  test('keeps the data directory in memory', () {
    // Nothing here outlives the container, and initdb is most of the startup.
    expect(postgresSpec().tmpfs, contains('/var/lib/postgresql/data'));
  });

  test('probes readiness over TCP as the user that will connect', () {
    // -h 127.0.0.1 is the load-bearing part: during initdb the entrypoint runs
    // a temporary server on the unix socket only, so a TCP probe cannot report
    // ready too early.
    final spec = postgresSpec(user: 'alice');

    expect(spec.healthcheck, isNotNull);
    expect(
      spec.healthcheck!.test.last,
      allOf(
        contains('pg_isready'),
        contains('-h 127.0.0.1'),
        contains('-U alice'),
      ),
    );
    expect(spec.waitFor, isA<HealthyWait>());
  });

  test('takes the auth mode env from the auth setup', () {
    expect(
      postgresSpec(auth: PgAuth.scram).env['POSTGRES_HOST_AUTH_METHOD'],
      'scram-sha-256',
    );
  });

  test('is shared by default and can be asked for a private one', () {
    expect(postgresSpec().lifetime, Lifetime.shared);
    expect(
      postgresSpec(lifetime: Lifetime.dedicated).lifetime,
      Lifetime.dedicated,
    );
  });

  test('says nothing about logging unless asked', () {
    expect(postgresSpec().command, isEmpty);
  });

  test('verbose logging turns on the statement log', () {
    final command = postgresSpec(verboseLogs: true).command;

    expect(command.first, 'postgres');
    expect(command.join(' '), contains('log_statement=all'));
    expect(command.join(' '), contains('log_connections=on'));
  });

  test('a connection limit becomes a server flag', () {
    final command = postgresSpec(maxConnections: 20).command;

    expect(command.first, 'postgres');
    expect(command.join(' '), contains('max_connections=20'));
  });

  test('two specs asking for the same thing are interchangeable', () {
    // Sharing is decided by the spec hash, so equal requests must produce
    // equal specs down to the ordering of everything in them.
    expect(
      specHashOf(postgresSpec(auth: PgAuth.md5)),
      specHashOf(postgresSpec(auth: PgAuth.md5)),
    );
    expect(
      specHashOf(postgresSpec(auth: PgAuth.md5)),
      isNot(specHashOf(postgresSpec(auth: PgAuth.scram))),
    );
    expect(
      specHashOf(postgresSpec()),
      isNot(specHashOf(postgresSpec(verboseLogs: true))),
    );
    expect(
      specHashOf(postgresSpec()),
      isNot(specHashOf(postgresSpec(maxConnections: 20))),
    );
  });
}
