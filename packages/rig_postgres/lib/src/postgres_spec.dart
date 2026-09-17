import 'package:rig/rig.dart';

import 'pg_auth.dart';
import 'pg_tls.dart';

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
  PgTlsMaterial? tlsMaterial,
  Map<String, String> labels = const {},
}) {
  final setup = setupFor(auth);
  final flags = [
    ...setup.serverFlags,
    if (maxConnections != null) ...['-c', 'max_connections=$maxConnections'],
    if (verboseLogs) ..._verboseFlags,
  ];

  final env = {
    'POSTGRES_USER': user,
    'POSTGRES_PASSWORD': password,
    'POSTGRES_DB': database,
    ...setup.env,
  };
  final healthcheck = Healthcheck(
    // -h 127.0.0.1 is the load-bearing part. During initialisation the
    // entrypoint runs a temporary server on the unix socket only, so a TCP
    // probe cannot be fooled into reporting ready while that is happening.
    test: ['CMD-SHELL', 'pg_isready -h 127.0.0.1 -U $user'],
    interval: const Duration(milliseconds: 250),
    timeout: const Duration(seconds: 3),
    retries: 60,
  );
  const waitFor = WaitFor.healthy(timeout: Duration(seconds: 120));
  // Nothing here outlives the container, and initdb is most of the startup.
  const tmpfs = {'/var/lib/postgresql/data'};

  if (tlsMaterial == null) {
    return ContainerSpec(
      image: 'postgres:$version',
      env: env,
      // `postgres` has to lead the argument list: the official entrypoint
      // treats a command starting with a flag as arguments to its own default.
      command: flags.isEmpty ? const [] : ['postgres', ...flags],
      exposedPorts: const [5432],
      tmpfs: tmpfs,
      labels: labels,
      healthcheck: healthcheck,
      waitFor: waitFor,
      lifetime: lifetime,
    );
  }

  const mountedCert = '/rig/server.crt';
  const mountedKey = '/rig/server.key';
  const usedCert = '/var/lib/postgresql/server.crt';
  const usedKey = '/var/lib/postgresql/server.key';

  // A bind mount arrives owned by root, and the server will not read a key it
  // does not own — nor one that is group or world readable. Copying it inside,
  // as root, before the entrypoint drops privileges, is what satisfies both
  // Docker's mount semantics and Postgres's permission check.
  //
  // The server flags are passed as positional arguments rather than joined
  // into the script string: a flag such as log_line_prefix contains spaces,
  // and `sh -c` would split it on them. `"$@"` carries them through as the
  // separate words they are.
  final script = [
    'install -o postgres -g postgres -m 644 $mountedCert $usedCert',
    'install -o postgres -g postgres -m 600 $mountedKey $usedKey',
    r'exec docker-entrypoint.sh "$@"',
  ].join(' && ');

  return ContainerSpec(
    image: 'postgres:$version',
    env: env,
    // After `-c script`, the next word is `$0` (consumed by the shell, not
    // part of "$@") and every word after that becomes "$@" — so `postgres`
    // has to come right after this placeholder `sh` for the entrypoint to
    // see it as its own first argument.
    command: [
      'sh',
      '-c',
      script,
      'sh',
      'postgres',
      ...flags,
      '-c',
      'ssl=on',
      '-c',
      'ssl_cert_file=$usedCert',
      '-c',
      'ssl_key_file=$usedKey',
    ],
    mounts: [
      Mount(hostPath: tlsMaterial.certificate.path, containerPath: mountedCert),
      Mount(hostPath: tlsMaterial.privateKey.path, containerPath: mountedKey),
    ],
    exposedPorts: const [5432],
    tmpfs: tmpfs,
    labels: labels,
    healthcheck: healthcheck,
    waitFor: waitFor,
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
