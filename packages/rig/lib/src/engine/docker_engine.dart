import '../spec/container_spec.dart';

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

  Future<void> stopContainer(String id, {Duration timeout});

  Future<void> removeContainer(String id);

  Future<void> close();
}
