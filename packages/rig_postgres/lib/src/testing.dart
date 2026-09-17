import 'package:rig/engine.dart';
import 'package:rig/rig.dart';
import 'package:test/test.dart';

import 'pg_auth.dart';
import 'postgres_lease.dart';
import 'postgres_spec.dart';

/// How much of the container a suite gets to itself.
enum PgIsolation {
  /// Connect to the container's own database. Suites sharing the container see
  /// each other's tables.
  none,
}

/// Declare that this suite needs a Postgres, and get a handle to it.
///
/// Suites asking for the same configuration share one container.
PostgresLease usePostgres({
  String version = '16-alpine',
  PgAuth auth = PgAuth.password,
  bool verboseLogs = false,
  int? maxConnections,
  String user = 'test',
  String password = 'test',
  String database = 'test_db',
  Lifetime lifetime = Lifetime.shared,
  PgIsolation isolation = PgIsolation.none,
  StateDir? stateDir,
  String? project,
}) {
  final spec = postgresSpec(
    version: version,
    auth: auth,
    verboseLogs: verboseLogs,
    maxConnections: maxConnections,
    user: user,
    password: password,
    database: database,
    lifetime: lifetime,
  );

  final container = useContainer(spec, stateDir: stateDir, project: project);
  final lease = PostgresLease(
    container: container,
    user: user,
    password: password,
    database: database,
  );

  setUpAll(() async {
    await confirmAuthMode(
      engine: await currentEngine(),
      containerId: container.containerId,
      auth: auth,
      user: user,
      password: password,
      database: database,
    );
  });

  return lease;
}

/// Re-hash the stored password so the auth mode is the one that was asked for.
///
/// Safe to run again: the statements are idempotent, and several suites sharing
/// one container will each run them.
Future<void> confirmAuthMode({
  required DockerEngine engine,
  required String containerId,
  required PgAuth auth,
  required String user,
  required String password,
  required String database,
}) async {
  final encryption = setupFor(auth).passwordEncryption;
  if (encryption == null) return;

  final result = await engine.exec(containerId, [
    'psql',
    '-U',
    user,
    '-d',
    database,
    '-v',
    'ON_ERROR_STOP=1',
    '-c',
    "SET password_encryption='$encryption'",
    '-c',
    "ALTER USER $user PASSWORD '$password'",
  ]);

  if (result.exitCode != 0) {
    throw StateError(
      'Could not set the stored password encryption to $encryption, so this '
      'container would not actually authenticate with ${auth.name}.\n'
      '${result.output}',
    );
  }
}
