import 'package:rig/module.dart';
import 'package:rig/rig.dart';
import 'package:test/test.dart';

import 'redis_lease.dart';
import 'redis_spec.dart';
import 'suite_index.dart';

/// How much of the container a suite gets to itself.
enum RedisIsolation {
  /// A database index of this suite's own, inside a container others share.
  /// Suites do not see each other's keys, and startup is still paid once.
  database,

  /// Connect to index 0 — what `redis://host:port/` means without an index
  /// of its own. Suites sharing the container that also ask for `none` see
  /// each other's keys there.
  none,
}

/// Declare that this suite needs a Redis, and get a handle to it.
///
/// Suites asking for the same configuration share one container.
RedisLease useRedis({
  String version = '7-alpine',
  String? password,
  int databases = 64,
  Lifetime lifetime = Lifetime.shared,
  RedisIsolation isolation = RedisIsolation.database,
  StateDir? stateDir,
  String? project,
  Map<String, String> labels = const {},
}) {
  // Resolved before setUpAll: the lock and marker paths below need
  // somewhere to live regardless of which branch runs.
  final resolvedStateDir = stateDir ?? StateDir.forUser();

  final spec = redisSpec(
    version: version,
    password: password,
    databases: databases,
    lifetime: lifetime,
    labels: labels,
  );

  final container = useContainer(spec, stateDir: stateDir, project: project);
  final lease = RedisLease(container: container, password: password);

  int? claimedIndex;

  setUpAll(() async {
    final engine = await currentEngine();

    if (isolation == RedisIsolation.none) {
      lease.bindDatabase(0);
      return;
    }

    // One suite at a time: two suites racing to scan for a free index on
    // the same container could both land on the one nobody else was using.
    await withExclusiveLock(
      resolvedStateDir.lockPath('redis-db-${container.containerId}'),
      () async {
        final index = await claimSuiteIndex(
          engine: engine,
          containerId: container.containerId,
          databases: databases,
          password: password,
          now: DateTime.now(),
          stateDir: resolvedStateDir,
        );
        claimedIndex = index;
        lease.bindDatabase(index);
      },
    );
  });

  tearDownAll(() async {
    final index = claimedIndex;
    if (index == null) return;
    await releaseSuiteIndex(
      engine: await currentEngine(),
      containerId: container.containerId,
      index: index,
      password: password,
      stateDir: resolvedStateDir,
    );
  });

  return lease;
}
