import 'dart:typed_data';

import '../spec/container_spec.dart';
import '../spec/labels.dart';

/// What the daemon reports about itself.
final class EngineVersion {
  const EngineVersion({
    required this.version,
    required this.apiVersion,
    required this.minApiVersion,
  });

  /// Daemon version, e.g. `29.5.3`.
  final String version;

  /// Highest API version the daemon speaks, e.g. `1.54`.
  final String apiVersion;

  /// Lowest API version the daemon still accepts, e.g. `1.40`.
  final String minApiVersion;
}

/// Docker's view of a container's healthcheck.
enum HealthStatus {
  /// No healthcheck is configured.
  none,

  /// Configured, and still inside its retry budget.
  starting,

  healthy,
  unhealthy,
}

/// What a command run inside a container produced.
final class ExecResult {
  const ExecResult({required this.exitCode, required this.output});

  /// The command's exit status, or -1 when Docker did not report one.
  final int exitCode;

  /// Combined stdout and stderr, in arrival order.
  final String output;
}

/// A container as it appears in a listing.
final class ContainerSummary {
  const ContainerSummary({
    required this.id,
    required this.image,
    required this.state,
    required this.labels,
    required this.created,
    required this.names,
  });

  final String id;
  final String image;

  /// `running`, `exited`, `created`, ...
  final String state;

  final Map<String, String> labels;

  /// When Docker created the container. rig reads this instead of keeping its
  /// own timestamp label, so the two can never disagree.
  final DateTime created;

  final List<String> names;
}

/// A network as it appears in a listing.
final class NetworkSummary {
  const NetworkSummary({
    required this.id,
    required this.name,
    required this.hasActiveEndpoints,
  });

  final String id;
  final String name;

  /// True when at least one container is currently attached. Docker refuses
  /// to remove a network while this is true.
  final bool hasActiveEndpoints;
}

/// A container as it appears on inspection.
final class ContainerInspect {
  const ContainerInspect({
    required this.id,
    required this.running,
    required this.health,
    required this.hostPorts,
    required this.labels,
    required this.created,
  });

  final String id;
  final bool running;
  final HealthStatus health;

  /// Container port to the host port Docker chose for it.
  final Map<int, int> hostPorts;

  final Map<String, String> labels;
  final DateTime created;
}

/// The slice of the Docker Engine API that rig needs.
///
/// An interface rather than a concrete client so that everything above it —
/// sharing, readiness, the CLI — can be tested without Docker. The only test
/// that talks to a real daemon is the integration suite.
abstract interface class DockerEngine {
  /// Throws [DockerUnavailable] when the daemon does not answer.
  Future<void> ping();

  Future<EngineVersion> version();

  Future<bool> imageExists(String image);

  /// Throws [ImagePullFailed] on failure.
  Future<void> pullImage(String image);

  /// Builds an image from [build] and tags it [tag].
  ///
  /// Throws [ImageBuildFailed] on failure, including a Dockerfile that built
  /// successfully as HTTP but failed inside the build (Docker answers `POST
  /// /build` with 200 and reports failure in the response stream).
  Future<void> buildImage(ContainerBuild build, String tag);

  /// Containers matching [filters], in Docker's filter form:
  /// `{'label': ['dev.dart-forge.rig=1'], 'status': ['running']}`.
  Future<List<ContainerSummary>> listContainers({
    Map<String, List<String>> filters,
    bool all,
  });

  /// Creates a container for [spec] carrying [labels]. Returns its id.
  ///
  /// [labels] replaces the spec's own labels: the caller has already merged
  /// rig's labels on top of them.
  Future<String> createContainer(
    ContainerSpec spec,
    Map<String, String> labels,
  );

  Future<void> startContainer(String id);

  Future<ContainerInspect> inspectContainer(String id);

  /// The last [lines] lines of the container's combined output.
  Future<String> logTail(String id, {int lines});

  /// The container's entire combined output, from the start.
  ///
  /// `WaitFor.logMessage` needs this rather than [logTail]: a suite that
  /// joins an already-running, shared container has to be able to find a
  /// message that was printed before it arrived, and a tail could have
  /// scrolled past it.
  Future<String> logs(String id);

  /// Runs [command] inside the container and waits for it to finish.
  ///
  /// Nothing is written to the command's stdin. That restriction is what lets
  /// this use the ordinary HTTP client: Docker offers a hijacked bidirectional
  /// stream for interactive execs, and avoiding it avoids writing a second
  /// HTTP implementation.
  ///
  /// A non-zero exit code is returned, not thrown. Whether a failed command is
  /// an error depends on what was asked, so the caller decides.
  Future<ExecResult> exec(String id, List<String> command);

  /// Writes [tarBytes] — a ustar archive — into the container, at [path].
  ///
  /// [path] must already exist inside the container as a directory: that
  /// is Docker's own rule for `PUT /containers/{id}/archive`, not something
  /// rig adds. Throws [CopyDestinationNotFound] when it does not.
  Future<void> putArchive(String id, String path, List<int> tarBytes);

  /// Reads the file or directory at [path] out of the container, as a
  /// ustar archive — what `GET /containers/{id}/archive` returns.
  Future<Uint8List> getArchive(String id, String path);

  Future<void> stopContainer(String id, {Duration timeout});

  Future<void> removeContainer(String id);

  /// Remove the image tagged [tag].
  ///
  /// rig can build images, so it can remove them: a caller that builds one
  /// should not have to reach for the Docker CLI to clean it up. Removing a
  /// tag that is already gone succeeds — that is the state the caller wanted.
  Future<void> removeImage(String tag);

  /// Creates a network named [name] carrying [labels] if none exists yet.
  ///
  /// Idempotent: an existing network with this name is left alone and
  /// treated as success. That is what makes it safe to call with no
  /// coordination when two specs name the same network at once — whichever
  /// request the daemon serves first wins, and the other sees "already
  /// there" rather than an error.
  Future<void> ensureNetwork(String name, Map<String, String> labels);

  /// Networks matching [filters], in the same form [listContainers] takes.
  Future<List<NetworkSummary>> listNetworks({
    Map<String, List<String>> filters,
  });

  /// Removes the network [id].
  ///
  /// Returns false, rather than throwing, when Docker refuses because a
  /// container is still attached — that is an expected outcome for a caller
  /// like `rig prune` walking every network it owns, not a failure of the
  /// remove call itself. Any other error still throws [EngineError].
  Future<bool> removeNetwork(String id);

  Future<void> close();
}

/// Every container rig made, whatever its lifetime or health.
///
/// The one place this filter is built. `rig ls`, `rig prune` and the
/// piling-up warning in `useContainer` all call this instead of building
/// the label filter themselves, so the three can never disagree about what
/// counts as rig's — one of them is the destructive path.
Future<List<ContainerSummary>> rigContainers(DockerEngine engine) =>
    engine.listContainers(
      filters: {
        'label': [rigMarkerLabel],
      },
    );
