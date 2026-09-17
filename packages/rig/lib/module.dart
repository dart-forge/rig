/// The surface a module built on top of rig is entitled to.
///
/// `rig_postgres` is the first module built on rig, and it needed pieces of
/// `engine.dart` — the lock, the project name — that library's own doc
/// comment disclaims as unstable. Depending on `engine.dart` would have tied
/// every future module to a library that changes with whatever rig itself
/// needs next.
///
/// This library is different: it is a promise. A module may depend on
/// exactly what is exported here, and it will not move out from under it.
library;

export 'src/engine/current.dart' show currentEngine, overrideEngine;
export 'src/engine/docker_engine.dart' show DockerEngine, ExecResult;
export 'src/lease/acquire.dart' show AcquiredContainer;
export 'src/lease/container_lease.dart' show ContainerLease;
export 'src/lease/lock.dart' show withExclusiveLock;
export 'src/project.dart' show currentProjectName;
// The function is promised, its output is not: adding a field to ContainerSpec
// changes every hash, as adding networks and builds already did. What a module
// may rely on is being able to ask whether two specs resolve to one container.
export 'src/spec/spec_hash.dart' show specHash;
