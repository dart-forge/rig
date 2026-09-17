import 'package:rig/rig.dart';
import 'package:test/test.dart';

import 'redis_lease.dart';
import 'redis_spec.dart';

/// Declare that this suite needs a Redis, and get a handle to it.
///
/// Suites asking for the same configuration share one container.
///
/// [databases] only sets the size of the container's own database pool for
/// now — this module does not yet give each suite an index of its own inside
/// it, so a suite sharing a container with another that also writes at index
/// 0 will see that other suite's keys. That per-suite isolation is not part
/// of this module yet.
RedisLease useRedis({
  String version = '7-alpine',
  String? password,
  int databases = 64,
  Lifetime lifetime = Lifetime.shared,
  StateDir? stateDir,
  String? project,
  Map<String, String> labels = const {},
}) {
  final spec = redisSpec(
    version: version,
    password: password,
    databases: databases,
    lifetime: lifetime,
    labels: labels,
  );

  final container = useContainer(spec, stateDir: stateDir, project: project);
  final lease = RedisLease(container: container, password: password);

  setUpAll(() {
    // Always 0 until this module assigns suites an index of their own; see
    // RedisLease.database.
    lease.bindDatabase(0);
  });

  return lease;
}
