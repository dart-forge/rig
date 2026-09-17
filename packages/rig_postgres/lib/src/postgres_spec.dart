import 'package:rig/rig.dart';

import 'pg_auth.dart';

/// The container a Postgres of this shape needs.
ContainerSpec postgresSpec({
  String version = '16-alpine',
  PgAuth auth = PgAuth.password,
  bool verboseLogs = false,
  int? maxConnections,
  String user = 'test',
  String password = 'test',
  String database = 'test_db',
  Lifetime lifetime = Lifetime.shared,
}) {
  final setup = setupFor(auth);
  final flags = [
    ...setup.serverFlags,
    if (maxConnections != null) ...['-c', 'max_connections=$maxConnections'],
    if (verboseLogs) ..._verboseFlags,
  ];

  return ContainerSpec(
    image: 'postgres:$version',
    env: {
      'POSTGRES_USER': user,
      'POSTGRES_PASSWORD': password,
      'POSTGRES_DB': database,
      ...setup.env,
    },
    // `postgres` has to lead the argument list: the official entrypoint treats
    // a command starting with a flag as arguments to its own default.
    command: flags.isEmpty ? const [] : ['postgres', ...flags],
    exposedPorts: const [5432],
    // Nothing here outlives the container, and initdb is most of the startup.
    tmpfs: const {'/var/lib/postgresql/data'},
    healthcheck: Healthcheck(
      // -h 127.0.0.1 is the load-bearing part. During initialisation the
      // entrypoint runs a temporary server on the unix socket only, so a TCP
      // probe cannot be fooled into reporting ready while that is happening.
      test: ['CMD-SHELL', 'pg_isready -h 127.0.0.1 -U $user'],
      interval: const Duration(milliseconds: 250),
      timeout: const Duration(seconds: 3),
      retries: 60,
    ),
    waitFor: const WaitFor.healthy(timeout: Duration(seconds: 120)),
    lifetime: lifetime,
  );
}

const List<String> _verboseFlags = [
  '-c',
  'log_statement=all',
  '-c',
  'log_connections=on',
  '-c',
  'log_disconnections=on',
  '-c',
  'log_duration=on',
  '-c',
  'log_line_prefix=%t [%p]: user=%u,db=%d,client=%h ',
];
