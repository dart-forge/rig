import 'package:rig/rig.dart';

/// A Postgres a test is using.
final class PostgresLease {
  PostgresLease({
    required this.container,
    required this.user,
    required this.password,
  });

  /// The container underneath. Reach for it to read logs or the id.
  final ContainerLease container;

  final String user;
  final String password;

  String? _database;

  /// The database this suite should connect to.
  ///
  /// Throws [LeaseNotBound] before `usePostgres`'s setUpAll has run, exactly
  /// like every other accessor here. Before that call, no database has
  /// necessarily been chosen yet — with the default isolation it does not
  /// exist until setUpAll creates it — so there is no value that would be
  /// honest to hand back. Returning the admin database in the meantime would
  /// be, since a helper that captures it at declaration time would go on
  /// writing into the shared database without ever being told isolation had
  /// quietly stopped applying.
  String get database {
    final database = _database;
    if (database == null) throw const LeaseNotBound();
    return database;
  }

  /// Points this lease at the database this suite should use. Called during
  /// setUpAll, for the same reason the container itself is bound there.
  void bindDatabase(String database) => _database = database;

  String get host => container.host;

  int get port => container.port(5432);

  /// A connection string a client will accept as-is.
  ///
  /// The credentials are percent-encoded: a password is not chosen with URL
  /// syntax in mind, and a caller should not have to think about it.
  String get url =>
      'postgresql://'
      '${Uri.encodeComponent(user)}:${Uri.encodeComponent(password)}'
      '@$host:$port/${Uri.encodeComponent(database)}';
}
