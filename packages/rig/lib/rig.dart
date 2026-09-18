/// Your tests start the containers they need.
library;

export 'src/engine/docker_engine.dart' show ExecResult;
export 'src/errors.dart';
export 'src/prune.dart';
export 'src/spec/container_spec.dart' hide NormalizedSpec, normalizeSpec;
export 'src/wait/wait_for.dart';
export 'src/lease/container_lease.dart';
export 'src/lease/state_dir.dart';
export 'src/testing.dart';
