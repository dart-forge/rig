import 'dart:io';

import 'package:test/test.dart';

import 'engine/current.dart';
import 'engine/docker_engine.dart';
import 'lease/acquire.dart';
import 'lease/container_lease.dart';
import 'lease/state_dir.dart';
import 'project.dart';
import 'spec/container_spec.dart';
import 'warn_threshold.dart';

export 'warn_threshold.dart' show defaultWarnAboveContainers;

bool _warned = false;

/// Declare that this suite needs [spec], and get a handle to it.
///
/// Registers the acquisition in `setUpAll` and the release in `tearDownAll`,
/// so call it where tests are declared:
///
/// ```dart
/// void main() {
///   final pg = useContainer(postgresSpec);
///
///   test('...', () async {
///     final conn = await connect(host: pg.host, port: pg.port(5432));
///   });
/// }
/// ```
///
/// The returned lease is readable from a test body or a `setUp`, not from the
/// top level of `main`: at that point the container has not been started.
///
/// [stateDir] is rarely worth setting; it exists so a CI job can point rig's
/// locks somewhere it controls.
///
/// The piling-up warning below this many containers is not a parameter here:
/// set `RIG_WARN_ABOVE` in the environment instead, since it is a
/// machine-wide concern, not a per-call one.
ContainerLease useContainer(
  ContainerSpec spec, {
  String? project,
  StateDir? stateDir,
}) {
  // Connected in setUpAll, which runs after this function has returned, so
  // the lease reaches for it lazily.
  DockerEngine? engine;
  final lease = ContainerLease.pending(() => engine!);

  setUpAll(() async {
    final connected = await currentEngine();
    engine = connected;
    lease.bind(
      await acquireContainer(
        spec: spec,
        engine: connected,
        stateDir: stateDir ?? StateDir.forUser(),
        project: project ?? currentProjectName(),
      ),
    );
    await _warnIfPilingUp(connected, warnThreshold(Platform.environment));
  });

  tearDownAll(lease.release);

  return lease;
}

/// Shared containers are never removed, so they accumulate. Nobody reads a
/// directory they were not told about, so say it once, in the test output.
Future<void> _warnIfPilingUp(DockerEngine engine, int threshold) async {
  if (_warned) return;
  _warned = true;

  try {
    final all = await rigContainers(engine);
    if (all.length > threshold) {
      // ignore: avoid_print
      print(
        'rig: ${all.length} containers are lying around. '
        'Clear them with: rig prune',
      );
    }
  } on Object {
    // A warning is not worth failing a test run over.
  }
}
