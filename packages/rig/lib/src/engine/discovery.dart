import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../errors.dart';

/// Where rig found a Docker daemon, and how.
final class DockerSocket {
  const DockerSocket({required this.path, required this.source});

  /// Filesystem path of the unix domain socket.
  final String path;

  /// How it was found, for error messages and `rig ls`:
  /// `DOCKER_HOST`, `context:colima`, or `well-known`.
  final String source;
}

/// The paths rig tries when neither DOCKER_HOST nor a context points anywhere
/// usable, in order.
List<String> wellKnownSocketPaths({
  required String home,
  Map<String, String> environment = const {},
}) {
  final xdg = environment['XDG_RUNTIME_DIR'];
  return [
    '/var/run/docker.sock',
    p.join(home, '.docker', 'run', 'docker.sock'), // Docker Desktop
    p.join(home, '.colima', 'default', 'docker.sock'), // colima
    p.join(home, '.rd', 'docker.sock'), // Rancher Desktop
    if (xdg != null && xdg.isNotEmpty) p.join(xdg, 'docker.sock'), // rootless
  ];
}

/// Find a Docker unix socket.
///
/// Tries DOCKER_HOST, then the current docker context, then the well-known
/// paths. A candidate that does not exist is skipped rather than fatal, so a
/// stale DOCKER_HOST does not mask a working Docker Desktop.
///
/// Throws [DockerUnavailable] listing every candidate when none exist. That
/// list is the whole point: "Docker not found" without it is unactionable.
DockerSocket discoverDockerSocket({
  required Map<String, String> environment,
  required String home,
  List<String>? wellKnown,
}) {
  final searched = <String>[];

  final fromEnv = _fromDockerHost(environment, searched);
  if (fromEnv != null) return fromEnv;

  final fromContext = _fromCurrentContext(home, searched);
  if (fromContext != null) return fromContext;

  final candidates =
      wellKnown ?? wellKnownSocketPaths(home: home, environment: environment);
  for (final path in candidates) {
    searched.add('$path (well-known)');
    if (_socketExists(path)) {
      return DockerSocket(path: path, source: 'well-known');
    }
  }

  throw DockerUnavailable(searched: searched);
}

DockerSocket? _fromDockerHost(Map<String, String> env, List<String> searched) {
  final raw = env['DOCKER_HOST'];
  if (raw == null || raw.isEmpty) {
    searched.add(r'$DOCKER_HOST (not set)');
    return null;
  }

  if (!raw.startsWith('unix://') && raw.contains('://')) {
    // Remote daemons are a different problem (TLS, credentials, port
    // forwarding). Say so rather than fail with a confusing socket error.
    throw DockerUnavailable(
      searched: [
        r'$DOCKER_HOST='
            '$raw',
      ],
      cause:
          'rig only speaks to a Docker unix socket in this version, '
          'and DOCKER_HOST is $raw',
    );
  }

  final path = raw.startsWith('unix://')
      ? raw.substring('unix://'.length)
      : raw;
  searched.add(
    r'$DOCKER_HOST='
    '$path',
  );
  if (!_socketExists(path)) return null;

  return DockerSocket(path: path, source: r'$DOCKER_HOST');
}

DockerSocket? _fromCurrentContext(String home, List<String> searched) {
  final contextName = _currentContextName(home);
  if (contextName == null || contextName == 'default') return null;

  final metaRoot = Directory(p.join(home, '.docker', 'contexts', 'meta'));
  if (!metaRoot.existsSync()) return null;

  for (final dir in metaRoot.listSync().whereType<Directory>()) {
    final host = _contextHost(p.join(dir.path, 'meta.json'), contextName);
    if (host == null) continue;

    final path = host.startsWith('unix://') ? host.substring(7) : host;
    searched.add('$path (context $contextName)');
    if (_socketExists(path)) {
      return DockerSocket(path: path, source: 'context:$contextName');
    }
  }
  return null;
}

String? _currentContextName(String home) {
  final config = File(p.join(home, '.docker', 'config.json'));
  if (!config.existsSync()) return null;
  try {
    final decoded = jsonDecode(config.readAsStringSync());
    if (decoded is! Map) return null;
    final name = decoded['currentContext'];
    return name is String && name.isNotEmpty ? name : null;
  } on FormatException {
    // A broken config must not stop rig from trying the well-known paths.
    return null;
  }
}

/// The docker endpoint declared by [metaPath], when it describes [wantedName].
///
/// The directory name is a hash of the context name, so rig matches on the
/// `Name` field instead of recomputing that hash.
String? _contextHost(String metaPath, String wantedName) {
  final meta = File(metaPath);
  if (!meta.existsSync()) return null;
  try {
    final decoded = jsonDecode(meta.readAsStringSync());
    if (decoded is! Map) return null;
    if (decoded['Name'] != wantedName) return null;

    final endpoints = decoded['Endpoints'];
    if (endpoints is! Map) return null;
    final docker = endpoints['docker'];
    if (docker is! Map) return null;
    final host = docker['Host'];
    return host is String && host.isNotEmpty ? host : null;
  } on FormatException {
    return null;
  }
}

/// True when [path] exists at all. A unix socket is not a regular file, so
/// this checks the type-agnostic entity.
bool _socketExists(String path) =>
    FileSystemEntity.typeSync(path, followLinks: true) !=
    FileSystemEntityType.notFound;
