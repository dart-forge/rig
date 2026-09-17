import 'dart:io';

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

  test('points PGDATA at the tmpfs regardless of version', () {
    // postgres:18-alpine's own default PGDATA is
    // /var/lib/postgresql/18/docker, not this path — 16 and 17 default to
    // it, but 18 does not. Without setting it explicitly, 18 would write to
    // the container's own writable layer, on disk, and the tmpfs above
    // would go unused.
    expect(
      postgresSpec(version: '18-alpine').env['PGDATA'],
      '/var/lib/postgresql/data',
    );
    expect(
      postgresSpec(version: '18-alpine').env['PGDATA'],
      postgresSpec(version: '18-alpine').tmpfs.single,
    );
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

  group('with TLS', () {
    final material = PgTlsMaterial(
      certificate: File('/cache/server.crt'),
      privateKey: File('/cache/server.key'),
    );

    test('mounts the material read-only', () {
      final spec = postgresSpec(tlsMaterial: material);

      expect(
        spec.mounts.map((m) => m.containerPath),
        containsAll(['/rig/server.crt', '/rig/server.key']),
      );
      expect(spec.mounts.every((m) => m.readOnly), isTrue);
    });

    test('copies it to a postgres-owned path before starting the server', () {
      // A bind mount arrives owned by root, and the server refuses to read a
      // key it does not own. Copying inside is what satisfies both Docker's
      // mount semantics and Postgres's permission check.
      final command = postgresSpec(tlsMaterial: material).command;

      expect(
        command.join(' '),
        contains('install -o postgres -g postgres -m 600'),
      );
      expect(command.join(' '), contains('/rig/server.key'));
      expect(command.join(' '), contains(r'exec docker-entrypoint.sh "$@"'));
    });

    test('turns ssl on and points the server at the copies', () {
      final command = postgresSpec(tlsMaterial: material).command;

      expect(command, containsAllInOrder(['-c', 'ssl=on']));
      expect(
        command,
        containsAllInOrder([
          '-c',
          'ssl_cert_file=/var/lib/postgresql/server.crt',
        ]),
      );
      expect(
        command,
        containsAllInOrder([
          '-c',
          'ssl_key_file=/var/lib/postgresql/server.key',
        ]),
      );
    });

    test('passes flags as separate words, not a space-joined string', () {
      // log_line_prefix contains spaces. Joined into the `sh -c` string, they
      // would be split on word boundaries and the server would exit with
      // "invalid argument". As positional arguments after `"$@"`, each flag
      // and its value survive as one word each.
      final command = postgresSpec(
        tlsMaterial: material,
        verboseLogs: true,
      ).command;

      expect(
        command,
        contains('log_line_prefix=%t [%p]: user=%u,db=%d,client=%h '),
      );
    });

    test(r'postgres leads the positional arguments after $0', () {
      // After `sh -c script`, the next word is consumed as $0 and everything
      // after that becomes "$@" inside the script. `postgres` has to be the
      // first word of "$@" for the entrypoint to treat it as its own argv[0].
      final command = postgresSpec(tlsMaterial: material).command;

      final scriptIndex = command.indexOf('-c') + 1;
      // command[scriptIndex + 1] is $0 (a placeholder, discarded by the
      // shell); command[scriptIndex + 2] is the first element of "$@".
      expect(command[scriptIndex + 2], 'postgres');
    });

    test('keeps the other server flags', () {
      final command = postgresSpec(
        tlsMaterial: material,
        verboseLogs: true,
        maxConnections: 20,
      ).command;

      expect(command, contains('log_statement=all'));
      expect(command, contains('max_connections=20'));
    });

    test('the material is part of what makes the container distinct', () {
      // Mounts are hashed by content, so a regenerated certificate must not
      // reuse a container running the old one.
      expect(
        postgresSpec().command,
        isNot(postgresSpec(tlsMaterial: material).command),
      );
    });
  });
}
