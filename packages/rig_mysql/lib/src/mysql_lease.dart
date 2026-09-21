import 'package:rig/module.dart';
import 'package:rig/rig.dart';

import 'mysql_exec.dart';

/// The server's authentication cache could not be cleared.
final class AuthCacheNotFlushed extends RigException {
  const AuthCacheNotFlushed({required this.detail});

  final String detail;

  @override
  String get message =>
      'Could not clear the server\'s authentication cache, so the next '
      'connection may still take the fast path — a test asserting the full '
      'authentication path would pass against the wrong one, with nothing '
      'to show for it.\n$detail';
}

/// A MySQL a test is using.
final class MySqlLease {
  MySqlLease({
    required this.container,
    required this.user,
    required this.password,
    required this.rootPassword,
  });

  /// The container underneath. Reach for it to read logs or the id.
  final ContainerLease container;

  final String user;
  final String password;

  /// The administrative password.
  ///
  /// Exposed because `MYSQL_USER` is not a superuser — unlike the user the
  /// Postgres image creates, which owns the server. A test that needs to
  /// create a schema, grant a privilege or read `mysql.user` has to be root,
  /// and without this it has no way to.
  final String rootPassword;

  String? _database;

  /// The database this suite should connect to.
  ///
  /// Throws [LeaseNotBound] before `useMySql`'s setUpAll has run, exactly
  /// like every other accessor here. Before that call, no database has
  /// necessarily been chosen yet — with the default isolation it does not
  /// exist until setUpAll creates it — so there is no value that would be
  /// honest to hand back. Returning the container's own database in the
  /// meantime would be worse, since a helper that captured it at declaration
  /// time would go on writing into the shared database without ever being
  /// told isolation had quietly stopped applying.
  String get database {
    final database = _database;
    if (database == null) throw const LeaseNotBound();
    return database;
  }

  /// Points this lease at the database this suite should use. Called during
  /// setUpAll, for the same reason the container itself is bound there.
  void bindDatabase(String database) => _database = database;

  String get host => container.host;

  int get port => container.port(3306);

  /// A connection string a client will accept as-is.
  ///
  /// The credentials are percent-encoded: a password is not chosen with URL
  /// syntax in mind, and a caller should not have to think about it.
  String get url =>
      'mysql://'
      '${Uri.encodeComponent(user)}:${Uri.encodeComponent(password)}'
      '@$host:$port/${Uri.encodeComponent(database)}';

  /// Clears the server's authentication cache, so the next connection has to
  /// authenticate in full.
  ///
  /// `caching_sha2_password` has two paths: a client the server's cache
  /// already knows proves itself with a SHA-256 scramble, and one it does not
  /// has to send the password in a form the server can recover. Only the
  /// second path involves the server's public key, so testing it at all means
  /// being able to empty that cache.
  ///
  /// This lives here rather than in the test because the client a test would
  /// reach for is the one under test. Asking it to run `FLUSH PRIVILEGES`
  /// first is circular: a driver that cannot connect cannot set up the
  /// conditions for its own connection test. Going through the container
  /// sidesteps that.
  Future<void> flushAuthCache() async {
    final result = await runMysql(
      await currentEngine(),
      container.containerId,
      rootPassword: rootPassword,
      sql: 'FLUSH PRIVILEGES',
    );
    if (result.exitCode != 0) {
      throw AuthCacheNotFlushed(detail: result.output);
    }
  }
}
