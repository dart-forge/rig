import 'package:rig/rig.dart';

/// A Postgres a test is using.
final class PostgresLease {
  PostgresLease({
    required this.container,
    required this.user,
    required this.password,
    required this.database,
  });

  /// The container underneath. Reach for it to read logs or the id.
  final ContainerLease container;

  final String user;
  final String password;

  /// The database this suite should connect to.
  final String database;

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
