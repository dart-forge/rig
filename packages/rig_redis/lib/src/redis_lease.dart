import 'package:rig/rig.dart';

/// A Redis a test is using.
final class RedisLease {
  RedisLease({required this.container, this.password});

  /// The container underneath. Reach for it to read logs, the id, or to run
  /// `redis-cli` yourself with [ContainerLease.exec].
  final ContainerLease container;

  /// Null when the container was started without `requirepass`.
  final String? password;

  int? _database;

  /// The database index this suite should `SELECT`.
  ///
  /// Always `0` for now — per-suite isolation across the [databases] a
  /// container was given is not part of this module yet. Throws
  /// [LeaseNotBound] before `useRedis`'s setUpAll has run, exactly like every
  /// other accessor here: returning `0` unconditionally would let a helper
  /// that captures it at declaration time look correct today and go on
  /// working after isolation lands, without ever being told to ask again.
  int get database {
    final database = _database;
    if (database == null) throw const LeaseNotBound();
    return database;
  }

  /// Points this lease at the database index this suite should use. Called
  /// during setUpAll, for the same reason the container itself is bound
  /// there.
  void bindDatabase(int database) => _database = database;

  String get host => container.host;

  int get port => container.port(6379);

  /// A connection string a client will accept as-is.
  ///
  /// The password is percent-encoded: it is not chosen with URL syntax in
  /// mind, and a caller should not have to think about it.
  String get url {
    final auth = password == null ? '' : ':${Uri.encodeComponent(password!)}@';
    return 'redis://$auth$host:$port/$database';
  }
}
