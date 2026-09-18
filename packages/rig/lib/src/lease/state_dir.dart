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

  /// Where a module records what it is holding inside a container.
  ///
  /// [kind] namespaces one module's markers from another's — `rig_postgres`
  /// uses `'postgres'`, `rig_redis` uses `'redis'`. A module writes into this
  /// to say "this resource inside the container is still mine" across
  /// isolates (`dart test` gives every suite file its own, so the filesystem
  /// is the one channel every isolate in a run can see); `rig prune` removes
  /// a container-id subdirectory once its container is no longer known to
  /// the daemon, since removing a container takes whatever that marker was
  /// protecting with it. `prune` sweeps `markers/*/<containerId>` without
  /// knowing any kind, so a new module needs no change there — which is the
  /// point of this layout.
  Directory markerDir(String kind) {
    if (!_kindPattern.hasMatch(kind)) {
      throw ArgumentError.value(
        kind,
        'kind',
        'must be lowercase letters, digits, "_" or "-" only, so it cannot '
            'escape the state directory as a path segment',
      );
    }
    return Directory(p.join(root.path, 'markers', kind));
  }

  void ensure() {
    Directory(p.join(root.path, 'locks')).createSync(recursive: true);
    failedDir.createSync(recursive: true);
  }
}

/// Non-empty, and safe as a single path segment: no `/` or `..` that could
/// walk a marker outside the state directory.
final RegExp _kindPattern = RegExp(r'^[a-z0-9_-]+$');
