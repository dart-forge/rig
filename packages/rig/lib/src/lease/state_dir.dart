import 'dart:io';

import 'package:path/path.dart' as p;

/// Where rig keeps the little state that has to outlive a test run.
///
/// Under the home directory rather than the system temp: temp is cleared on
/// reboot but containers are not, so the two would drift apart.
final class StateDir {
  StateDir(this.root);

  factory StateDir.forUser({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    final home = env['HOME'] ?? env['USERPROFILE'] ?? '.';
    return StateDir(Directory(p.join(home, '.rig')));
  }

  final Directory root;

  /// The lock guarding "create at most one container for this hash".
  String lockPath(String hash) => p.join(root.path, 'locks', '$hash.lock');

  /// Where a container that never became usable is recorded.
  ///
  /// This is a file rather than a label because Docker cannot change a
  /// container's labels after it is created.
  File failedMarker(String containerId) =>
      File(p.join(failedDir.path, '$containerId.json'));

  Directory get failedDir => Directory(p.join(root.path, 'failed'));

  /// Deterministically generated TLS material, cached so that a spec which
  /// mounts a certificate keeps the same hash between runs.
  Directory get certsDir => Directory(p.join(root.path, 'certs'));

  /// Where a running suite's per-database markers live, one subdirectory per
  /// container id. A module (rig_postgres is the first) writes into this to
  /// say "this database is still mine" across isolates; `rig prune` removes
  /// a subdirectory once its container is no longer known to the daemon,
  /// since removing a container takes whatever that marker was protecting
  /// with it.
  Directory get suitesDir => Directory(p.join(root.path, 'suites'));

  void ensure() {
    Directory(p.join(root.path, 'locks')).createSync(recursive: true);
    failedDir.createSync(recursive: true);
  }
}
