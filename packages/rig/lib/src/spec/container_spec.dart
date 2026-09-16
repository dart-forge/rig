import '../wait/wait_for.dart';

/// Whether a container is shared between test suites or belongs to one.
enum Lifetime {
  /// Reused by any suite whose spec hashes the same, and left running after
  /// the tests finish so the next run does not pay for startup again.
  shared,

  /// Created for this suite and removed when it finishes. Use it when a test
  /// would disturb others — connection limits, killing backends, restarts.
  dedicated,
}

/// A host file or directory made visible inside the container.
final class Mount {
  const Mount({
    required this.hostPath,
    required this.containerPath,
    this.readOnly = true,
  });

  final String hostPath;
  final String containerPath;
  final bool readOnly;
}

/// The one ordering for a list of mounts, shared by [normalizeSpec] and
/// `specHash`'s content digest.
///
/// Both need mounts in a fixed order, and disagreeing about that order would
/// let the canonical lines describe a different set of mounts than the
/// content digests do. [Mount.hostPath] is the tie-break rather than leaving
/// it to `List.sort`'s incidental behaviour, which Dart does not promise is
/// stable.
int compareMounts(Mount a, Mount b) {
  final byContainerPath = a.containerPath.compareTo(b.containerPath);
  if (byContainerPath != 0) return byContainerPath;
  return a.hostPath.compareTo(b.hostPath);
}

/// A health probe rig installs when creating the container.
///
/// Most official images ship no HEALTHCHECK, so rig adds one at create time
/// rather than reading logs to guess when a service is up.
final class Healthcheck {
  const Healthcheck({
    required this.test,
    this.interval = const Duration(seconds: 1),
    this.timeout = const Duration(seconds: 3),
    this.retries = 3,
    this.startPeriod = Duration.zero,
  });

  /// The probe, in Docker's form: `['CMD-SHELL', 'pg_isready -h 127.0.0.1']`.
  final List<String> test;

  final Duration interval;
  final Duration timeout;
  final int retries;
  final Duration startPeriod;
}

/// An immutable description of a container to run.
///
/// Const-constructible on purpose: rig hashes the spec to decide whether a
/// container it already has can serve this suite.
final class ContainerSpec {
  const ContainerSpec({
    required this.image,
    required this.waitFor,
    this.env = const {},
    this.command = const [],
    this.entrypoint = const [],
    this.exposedPorts = const [],
    this.tmpfs = const {},
    this.mounts = const [],
    this.labels = const {},
    this.user,
    this.workingDir,
    this.privileged = false,
    this.networkMode,
    this.healthcheck,
    this.lifetime = Lifetime.shared,
  });

  /// Image reference including the tag, e.g. `postgres:16-alpine`.
  final String image;

  /// How rig decides the container is usable. Required: readiness is the
  /// crux, and a silent default would be the wrong one about half the time.
  final WaitFor waitFor;

  final Map<String, String> env;
  final List<String> command;
  final List<String> entrypoint;

  /// Ports inside the container to publish. Docker picks the host ports.
  final List<int> exposedPorts;

  final Set<String> tmpfs;
  final List<Mount> mounts;

  /// Labels for the caller's own use. rig adds its own on top and excludes
  /// these from the hash, so tagging a container never splits sharing.
  final Map<String, String> labels;

  final String? user;
  final String? workingDir;
  final bool privileged;
  final String? networkMode;
  final Healthcheck? healthcheck;
  final Lifetime lifetime;

  /// A copy of this spec with the given fields replaced.
  ///
  /// [ContainerSpec] is const-constructible so it can be shared and hashed,
  /// which means a shared `const` spec cannot be tweaked in place. The
  /// motivating case is flipping [lifetime] for one suite — a connection
  /// pool test that must not share its container — without repeating every
  /// other field.
  ContainerSpec copyWith({
    String? image,
    WaitFor? waitFor,
    Map<String, String>? env,
    List<String>? command,
    List<String>? entrypoint,
    List<int>? exposedPorts,
    Set<String>? tmpfs,
    List<Mount>? mounts,
    Map<String, String>? labels,
    String? user,
    String? workingDir,
    bool? privileged,
    String? networkMode,
    Healthcheck? healthcheck,
    Lifetime? lifetime,
  }) {
    return ContainerSpec(
      image: image ?? this.image,
      waitFor: waitFor ?? this.waitFor,
      env: env ?? this.env,
      command: command ?? this.command,
      entrypoint: entrypoint ?? this.entrypoint,
      exposedPorts: exposedPorts ?? this.exposedPorts,
      tmpfs: tmpfs ?? this.tmpfs,
      mounts: mounts ?? this.mounts,
      labels: labels ?? this.labels,
      user: user ?? this.user,
      workingDir: workingDir ?? this.workingDir,
      privileged: privileged ?? this.privileged,
      networkMode: networkMode ?? this.networkMode,
      healthcheck: healthcheck ?? this.healthcheck,
      lifetime: lifetime ?? this.lifetime,
    );
  }
}

/// A spec reduced to a canonical, order-independent form.
final class NormalizedSpec {
  const NormalizedSpec(this.canonicalLines);

  /// One line per meaningful property, in a fixed order. Two specs that
  /// would produce the same container produce the same lines.
  ///
  /// A mount appears by its container path and access mode. The host path is
  /// deliberately absent: what the container sees is the content, which
  /// `specHash` folds in by reading the file. Leaving the host path out is
  /// what lets the same files at a different absolute path — another
  /// checkout, a CI runner — still share one container.
  final List<String> canonicalLines;
}

/// Reduce [spec] to the form rig hashes.
///
/// Excluded on purpose: `waitFor` (does not change the container, so suites
/// that wait differently can still share one), `lifetime` (the same container
/// either way), and `labels` (annotating must not split sharing).
NormalizedSpec normalizeSpec(ContainerSpec spec) {
  final sortedEnv = spec.env.keys.toList()..sort();
  final sortedPorts = spec.exposedPorts.toSet().toList()..sort();
  final sortedTmpfs = spec.tmpfs.toList()..sort();
  final sortedMounts = spec.mounts.toList()..sort(compareMounts);

  return NormalizedSpec([
    'image=${spec.image}',
    for (final key in sortedEnv) 'env=$key=${spec.env[key]}',
    // argv order is meaningful, so these keep their order.
    for (final arg in spec.entrypoint) 'entrypoint=$arg',
    for (final arg in spec.command) 'cmd=$arg',
    for (final port in sortedPorts) 'port=$port',
    for (final path in sortedTmpfs) 'tmpfs=$path',
    for (final m in sortedMounts)
      'mount=${m.containerPath}:${m.readOnly ? 'ro' : 'rw'}',
    if (spec.user != null) 'user=${spec.user}',
    if (spec.workingDir != null) 'workdir=${spec.workingDir}',
    if (spec.privileged) 'privileged=true',
    if (spec.networkMode != null) 'network=${spec.networkMode}',
    ..._healthcheckLines(spec.healthcheck),
  ]);
}

List<String> _healthcheckLines(Healthcheck? hc) {
  if (hc == null) return const [];
  return [
    for (final arg in hc.test) 'hc=$arg',
    'hc.interval=${hc.interval.inMilliseconds}',
    'hc.timeout=${hc.timeout.inMilliseconds}',
    'hc.retries=${hc.retries}',
    'hc.startPeriod=${hc.startPeriod.inMilliseconds}',
  ];
}
