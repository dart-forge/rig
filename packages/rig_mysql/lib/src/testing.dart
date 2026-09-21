import 'package:rig/module.dart';
import 'package:rig/rig.dart';
import 'package:test/test.dart';

import 'mysql_auth.dart';
import 'mysql_exec.dart';
import 'mysql_lease.dart';
import 'mysql_spec.dart';
import 'mysql_tls.dart';
import 'suite_database.dart';

/// How much of the container a suite gets to itself.
enum MySqlIsolation {
  /// A database of this suite's own, inside a container others share. Suites
  /// do not see each other's tables, and startup is still paid once.
  database,

  /// Connect to the container's own database. Suites sharing the container
  /// see each other's tables.
  none,
}

/// Declare that this suite needs a MySQL, and get a handle to it.
///
/// Suites asking for the same configuration share one container.
MySqlLease useMySql({
  String version = '8.4',
  MySqlAuth auth = MySqlAuth.cachingSha2,
  bool verboseLogs = false,
  int? maxConnections,
  String user = 'test',
  String password = 'test',
  String rootPassword = 'root',
  String database = 'test_db',
  Lifetime lifetime = Lifetime.shared,
  MySqlIsolation isolation = MySqlIsolation.database,
  StateDir? stateDir,
  String? project,
  MySqlTls tls = const MySqlTls.serverDefault(),
  Map<String, String> labels = const {},
}) {
  // Resolved before the spec is built because `useContainer` needs a
  // finished spec at declaration time, before any `setUpAll` exists to await
  // anything in.
  final resolvedStateDir = stateDir ?? StateDir.forUser();

  final spec = mysqlSpec(
    version: version,
    auth: auth,
    verboseLogs: verboseLogs,
    maxConnections: maxConnections,
    user: user,
    password: password,
    rootPassword: rootPassword,
    database: database,
    lifetime: lifetime,
    tls: tls,
    labels: labels,
  );

  final container = useContainer(spec, stateDir: stateDir, project: project);
  final lease = MySqlLease(
    container: container,
    user: user,
    password: password,
    rootPassword: rootPassword,
  );

  String? suiteDatabase;

  setUpAll(() async {
    final engine = await currentEngine();

    await confirmAuthMode(
      engine: engine,
      containerId: container.containerId,
      auth: auth,
      rootPassword: rootPassword,
      user: user,
      password: password,
    );

    if (isolation == MySqlIsolation.none) {
      lease.bindDatabase(database);
      return;
    }

    // One suite at a time: creating a database and clearing abandoned ones
    // are not things several suites should do to one container at once.
    await withExclusiveLock(
      resolvedStateDir.lockPath('mysql-init-${container.containerId}'),
      () async {
        await dropStaleSuiteDatabases(
          engine: engine,
          containerId: container.containerId,
          rootPassword: rootPassword,
          now: DateTime.now(),
          stateDir: resolvedStateDir,
        );

        final name = suiteDatabaseName(
          project: project ?? currentProjectName(),
          now: DateTime.now(),
          token: newSuiteToken(),
        );
        await createSuiteDatabase(
          engine: engine,
          containerId: container.containerId,
          rootPassword: rootPassword,
          user: user,
          database: name,
          stateDir: resolvedStateDir,
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
      rootPassword: rootPassword,
      database: name,
      stateDir: resolvedStateDir,
    );
  });

  return lease;
}

/// The stored password could not be written again under the plugin the auth
/// mode asked for.
final class AuthConfirmationFailed extends RigException {
  const AuthConfirmationFailed({required this.plugin, required this.detail});

  final String plugin;
  final String detail;

  @override
  String get message =>
      'Could not store the password under $plugin, so this container would '
      'not actually authenticate with $plugin — it would quietly accept '
      'whatever the image hashed the password as during initialisation, and '
      'every assertion about the auth mode would mean nothing.\n$detail\n\n'
      'Check that the container is healthy (docker logs), that the root '
      'password reached it, and that the plugin is loaded (8.4 does not load '
      'mysql_native_password by default).';
}

/// Stores the password again under the plugin [auth] asks for.
///
/// This is the half that is easy to miss. The image creates the user during
/// initialisation and stores the password under whatever the server's default
/// plugin is at that moment; changing the default afterwards does not re-hash
/// what is already stored. Faced with a stored caching_sha2 verifier, the
/// server authenticates with caching_sha2 — the connection succeeds and the
/// mode the test asked for is never exercised. So the password is written
/// again after startup, and the mode becomes something the test asserts
/// rather than hopes for.
///
/// Safe to run again: the statement is idempotent, and several suites sharing
/// one container will each run it.
Future<void> confirmAuthMode({
  required DockerEngine engine,
  required String containerId,
  required MySqlAuth auth,
  required String rootPassword,
  required String user,
  required String password,
}) async {
  // The plugin name is not quoted: it comes from this package's own enum, not
  // from a caller, and MySQL's grammar takes it as a bare identifier here.
  // The user and the password are quoted, because both are the caller's.
  //
  // The host has to be '%', which is what the entrypoint created the user
  // with. Naming a different one would create a second account rather than
  // change this one, and the test would authenticate as whichever the server
  // picked.
  final plugin = setupFor(auth).plugin;
  final result = await runMysql(
    engine,
    containerId,
    rootPassword: rootPassword,
    sql:
        'ALTER USER ${mysqlStringLiteral(user)}@${mysqlStringLiteral('%')} '
        'IDENTIFIED WITH $plugin BY ${mysqlStringLiteral(password)}',
  );

  if (result.exitCode != 0) {
    throw AuthConfirmationFailed(plugin: plugin, detail: result.output);
  }
}
