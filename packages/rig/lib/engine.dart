/// The Docker Engine surface rig uses.
///
/// Published so rig's own tooling (`rig_cli`) and rig modules can reach it.
/// Not part of rig's stable API: it changes with what rig needs.
library;

export 'src/engine/connect.dart';
export 'src/engine/current.dart';
export 'src/engine/docker_engine.dart';
export 'src/spec/labels.dart';
export 'src/lease/acquire.dart';
export 'src/spec/spec_hash.dart';
export 'src/lease/lock.dart' show defaultLockStaleAfter, withExclusiveLock;
export 'src/project.dart';
