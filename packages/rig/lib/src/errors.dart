/// Everything rig throws. Sealed so a caller can switch over the cases.
sealed class RigException implements Exception {
  const RigException();

  /// The text shown to whoever ran the test. Written to be actionable:
  /// what rig wanted, what it saw, and what to do about it.
  String get message;

  @override
  String toString() => message;
}

/// rig could not find or reach a Docker daemon.
final class DockerUnavailable extends RigException {
  const DockerUnavailable({required this.searched, this.cause});

  /// Every location rig looked at, in the order it tried them.
  final List<String> searched;

  /// The error from the last attempt, when there was one.
  final Object? cause;

  @override
  String get message {
    final lines = [
      'Could not reach Docker. Is Docker running?',
      '',
      'rig looked at:',
      for (final path in searched) '  - $path',
    ];
    if (cause != null) {
      lines
        ..add('')
        ..add('Last error: $cause');
    }
    return lines.join('\n');
  }
}

/// The daemon requires a newer API version than rig speaks.
final class EngineApiTooOld extends RigException {
  const EngineApiTooOld({required this.used, required this.minSupported});

  /// The API version rig asked for.
  final String used;

  /// The daemon's MinAPIVersion.
  final String minSupported;

  @override
  String get message =>
      'This Docker daemon no longer accepts API $used '
      '(its minimum is $minSupported). Upgrade rig.';
}

/// The daemon answered a request with an error status.
final class EngineError extends RigException {
  const EngineError({
    required this.method,
    required this.path,
    required this.statusCode,
    required this.body,
  });

  final String method;
  final String path;
  final int statusCode;
  final String body;

  @override
  String get message => 'Docker answered $statusCode to $method $path:\n$body';
}

/// Pulling an image failed.
final class ImagePullFailed extends RigException {
  const ImagePullFailed({required this.image, required this.detail});

  final String image;
  final String detail;

  @override
  String get message => 'Could not pull $image: $detail';
}

/// A container started but never became usable within the timeout.
final class ReadyTimeout extends RigException {
  const ReadyTimeout({
    required this.containerId,
    required this.waited,
    required this.waitingFor,
    required this.logTail,
  });

  final String containerId;
  final Duration waited;

  /// Human description of the wait strategy, e.g. 'health status to become healthy'.
  final String waitingFor;

  /// The tail of the container's output, or empty when it produced none.
  final String logTail;

  @override
  String get message => [
    'Waited ${waited.inSeconds}s for $waitingFor, and it never happened.',
    '',
    'Container $containerId is still running so you can look at it:',
    '  docker logs $containerId',
    '  docker exec -it $containerId sh',
    '',
    'Last output:',
    if (logTail.isEmpty) '  (no output)' else logTail,
  ].join('\n');
}

/// A lease was read before its container was acquired.
final class LeaseNotBound extends RigException {
  const LeaseNotBound();

  @override
  String get message =>
      'This container has not started yet. useContainer() acquires it in '
      'setUpAll, so read host/port inside a test body or a later setUp, '
      'not at the top level of main().';
}

/// `WaitFor.healthy()` was used on a container that has no healthcheck.
///
/// This is a mistake in the spec, not a slow container, so it fails at once
/// instead of after the timeout.
final class NoHealthcheck extends RigException {
  const NoHealthcheck({required this.containerId});

  final String containerId;

  @override
  String get message =>
      'WaitFor.healthy() needs a healthcheck, and container $containerId '
      'has none.\n\n'
      'Most official images ship without one. Either give the spec a '
      'healthcheck:\n'
      "  healthcheck: Healthcheck(test: ['CMD-SHELL', 'pg_isready -h 127.0.0.1'])\n"
      'or wait on something else, such as WaitFor.port(5432).';
}

/// The container stopped on its own while rig was waiting for it.
final class ContainerExited extends RigException {
  const ContainerExited({required this.containerId, required this.logTail});

  final String containerId;
  final String logTail;

  @override
  String get message => [
    'Container $containerId exited while rig was waiting for it to '
        'become usable.',
    '',
    'Last output:',
    if (logTail.isEmpty) '  (no output)' else logTail,
  ].join('\n');
}

/// A port was read that the spec never published.
final class PortNotPublished extends RigException {
  const PortNotPublished({
    required this.containerPort,
    required this.published,
  });

  final int containerPort;
  final List<int> published;

  @override
  String get message => published.isEmpty
      ? 'Port $containerPort is not published, and neither is any other. '
            'Add it to the spec: exposedPorts: [$containerPort].'
      : 'Port $containerPort is not published. This container publishes '
            '${published.join(', ')}. Add it to the spec: '
            'exposedPorts: [${[...published, containerPort].join(', ')}].';
}

/// Another holder kept the lock for the whole timeout.
final class LockTimeout extends RigException {
  const LockTimeout({required this.lockPath, required this.waited});

  final String lockPath;
  final Duration waited;

  @override
  String get message =>
      'Waited ${waited.inSeconds}s for another test to finish starting a '
      'shared container, and it did not.\n\n'
      'The lock is $lockPath. If no tests are running, delete it.';
}
