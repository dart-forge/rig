import 'package:rig/engine.dart';
import 'package:rig/rig.dart';
import 'package:test/test.dart';

import 'pg_auth.dart';
import 'postgres_lease.dart';
import 'postgres_spec.dart';
import 'suite_database.dart';

/// How much of the container a suite gets to itself.
enum PgIsolation {
  /// A database of this suite's own, inside a container others share. Suites
  /// do not see each other's tables, and startup is still paid once.
  database,

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
  PgIsolation isolation = PgIsolation.database,
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

  final resolvedStateDir = stateDir ?? StateDir.forUser();
  String? suiteDatabase;

  setUpAll(() async {
    final engine = await currentEngine();

    await confirmAuthMode(
      engine: engine,
      containerId: container.containerId,
      auth: auth,
      user: user,
      password: password,
      database: database,
    );

    if (isolation == PgIsolation.none) return;

    // One suite at a time: creating a database and clearing abandoned ones are
    // not things several suites should do to one container at once.
    await withExclusiveLock(
      resolvedStateDir.lockPath('pg-init-${container.containerId}'),
      () async {
        await dropStaleSuiteDatabases(
          engine: engine,
          containerId: container.containerId,
          user: user,
          adminDatabase: database,
          now: DateTime.now(),
        );

        final name = suiteDatabaseName(
          project: project ?? currentProjectName(),
          now: DateTime.now(),
          token: newSuiteToken(),
        );
        await createSuiteDatabase(
          engine: engine,
          containerId: container.containerId,
          user: user,
          adminDatabase: database,
          database: name,
        );
        suiteDatabase = name;
        lease.bindDatabase(name);
      },
    );
  });

  tearDownAll(() async {
    final name = suiteDatabase;
    if (name == null) return;
    await dropSuiteDatabase(
      engine: await currentEngine(),
      containerId: container.containerId,
      user: user,
      adminDatabase: database,
      database: name,
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
