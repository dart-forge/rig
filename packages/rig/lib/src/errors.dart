/// Everything rig throws.
///
/// Not sealed: a module in another package defines its own failures as rig
/// failures, so that a consumer catching this catches all of them. Sealing it
/// would buy exhaustive switching that nothing in this project does, at the
/// price of every module having to invent a parallel hierarchy.
abstract class RigException implements Exception {
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
  String get message =>
      'Could not pull $image: $detail\n\n'
      'Check that the image name and tag are correct, and that '
      '`docker pull $image` works from this machine.';
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

/// A command run inside a container with `ContainerLease.exec` exited
/// non-zero, and the caller did not opt out with `expectSuccess: false`.
///
/// Silently ignoring an exit code is a mistake this library has already
/// made once: a cleanup step reported that it had dropped something when
/// the drop had actually failed, because nothing checked the result. Once
/// that happens, whatever the failed step was protecting is gone along with
/// the record that it ever ran. Throwing by default means a caller has to
/// say, in the code, that a failure here is fine.
final class ExecFailed extends RigException {
  const ExecFailed({
    required this.command,
    required this.exitCode,
    required this.output,
  });

  /// The command that was run.
  final List<String> command;

  final int exitCode;

  /// Combined stdout and stderr, or empty when the command produced none.
  final String output;

  @override
  String get message => [
    'Command exited $exitCode: ${command.join(' ')}',
    '',
    'Output:',
    if (output.isEmpty) '  (no output)' else output,
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

/// A `.dockerignore` line contains a pattern rig does not interpret — a
/// character class (`[...]`) is the only one, so far.
///
/// The daemon does not interpret `.dockerignore` at all: excluding files is
/// entirely the client's job, and getting it wrong does not fail the build —
/// it ships a file the author meant to exclude inside the image. Silently
/// skipping a pattern it cannot understand would risk exactly that, so rig
/// throws instead of guessing.
final class DockerignorePatternNotSupported extends RigException {
  const DockerignorePatternNotSupported({
    required this.line,
    required this.pattern,
  });

  /// 1-based line number within the `.dockerignore` file.
  final int line;

  /// The pattern text on that line, after stripping a leading `!` — what
  /// could not be understood, not the whole line.
  final String pattern;

  @override
  String get message =>
      'Could not interpret .dockerignore line $line: "$pattern"\n\n'
      'rig only understands literal path segments, `*`, `?`, `**`, and `!` '
      'negation. Character classes like `[a-z]` are not supported. When in '
      'doubt, rig refuses rather than risk sending a file you meant to '
      'exclude.';
}

/// A build context contains a symlink.
///
/// Following it could pull in something from outside the context entirely;
/// skipping it would build a subtly different image than the one on disk.
/// Neither is safe to guess at.
final class SymlinkInBuildContext extends RigException {
  const SymlinkInBuildContext({required this.path});

  final String path;

  @override
  String get message =>
      'Build context contains a symlink at $path, which rig does not '
      'support.\n\nReplace it with a real file or directory.';
}

/// A build context path is too long for ustar to represent.
final class BuildContextPathTooLong extends RigException {
  const BuildContextPathTooLong({required this.path});

  final String path;

  @override
  String get message =>
      'Path is too long to put in a tar build context: $path\n\n'
      'ustar allows at most 100 bytes for a file name and 155 for its '
      'directory prefix. Shorten the path.';
}

/// Building an image from a Dockerfile failed.
///
/// Docker answers `POST /build` with 200 and reports failure inside the
/// response stream, so this can surface long after the request looked like
/// it succeeded. [detail] carries the build output so the caller can see
/// which step failed, not just that one did.
final class ImageBuildFailed extends RigException {
  const ImageBuildFailed({required this.tag, required this.detail});

  /// The tag the build was asked to produce.
  final String tag;

  final String detail;

  @override
  String get message => 'Could not build $tag:\n\n$detail';
}

/// `PUT /containers/{id}/archive` answered 404 because [directory] does not
/// already exist inside the container.
///
/// Docker's own 404 calls the missing directory "the file", which reads as
/// if the *destination* were a file rig failed to find — backwards from
/// what actually happened. rig also does not create the directory itself:
/// doing that quietly would turn a mistyped destination into a file that
/// lands somewhere the caller never intended, with no error to notice.
final class CopyDestinationNotFound extends RigException {
  const CopyDestinationNotFound({
    required this.containerId,
    required this.directory,
  });

  final String containerId;
  final String directory;

  @override
  String get message =>
      'Container $containerId has no directory $directory.\n\n'
      'Copying a file or directory into a container requires the '
      'destination to already exist as a directory — Docker will not '
      'create one. Create it first, e.g.:\n'
      "  await lease.exec(['mkdir', '-p', '$directory']);";
}

/// `ContainerLease.putFile` was given a mode string that is not 3 or 4
/// octal digits.
final class InvalidFileMode extends RigException {
  const InvalidFileMode({required this.mode});

  final String mode;

  @override
  String get message =>
      "File mode must be 3 or 4 octal digits, like '644' or '4755'; got "
      "'$mode'.";
}

/// `ContainerLease.getFile` asked for [requestedPath], but the archive
/// Docker sent back did not hold exactly one regular file.
///
/// Most often this means [requestedPath] names a directory: Docker
/// archives one as multiple entries rather than the single entry a file
/// produces.
final class UnexpectedArchiveContents extends RigException {
  const UnexpectedArchiveContents({
    required this.requestedPath,
    required this.entryNames,
  });

  final String requestedPath;
  final List<String> entryNames;

  @override
  String get message =>
      'getFile($requestedPath) expected a single regular file, but the '
      'archive Docker returned contained ${entryNames.length} '
      'entr${entryNames.length == 1 ? 'y' : 'ies'}: '
      '${entryNames.join(', ')}.\n\n'
      'This usually means the path names a directory, not a file.';
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
