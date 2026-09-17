import 'package:rig/rig.dart';

/// A Postgres a test is using.
final class PostgresLease {
  PostgresLease({
    required this.container,
    required this.user,
    required this.password,
    required String database,
    // The public parameter is `database`; the field is private so
    // `bindDatabase` can change it later, which rules out an initializing
    // formal (that would rename the parameter to `_database`).
    // ignore: prefer_initializing_formals
  }) : _database = database;

  /// The container underneath. Reach for it to read logs or the id.
  final ContainerLease container;

  final String user;
  final String password;

  String _database;

  /// The database this suite should connect to.
  String get database => _database;

  /// Points this lease at the database created for the suite. Called during
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
