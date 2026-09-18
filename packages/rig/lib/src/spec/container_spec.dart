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

/// A file placed inside the container before it starts.
///
/// Exists because a server that reads its configuration at startup cannot be
/// reached by `ContainerLease.putFile`: that writes into a container that is
/// already running, which is too late for anything read once, at boot. The
/// other way to get a file in ahead of time is a bind mount, and a mount
/// brings the *host's* ownership with it — a file meant for a non-root
/// process inside the container can come through unreadable, the same
/// problem `putFile`'s own `uid`/`gid` parameters exist to avoid. This is
/// that fix, applied before the container ever starts.
///
/// [uid] and [gid] must be numeric ids, not names: Docker ignores a tar
/// entry's `uname`/`gname` and only ever applies the numeric `uid`/`gid` it
/// carries (measured against a real daemon — see the design this
/// implements). rig has no way to resolve a name to a number for an
/// arbitrary image, so the caller has to know the numeric id their image
/// actually runs as.
final class ContainerFile {
  const ContainerFile(
    this.path,
    this.content, {
    this.mode = '644',
    this.uid = 0,
    this.gid = 0,
  });

  /// Absolute path inside the container.
  final String path;

  final List<int> content;

  /// POSIX permission bits as a 3- or 4-digit octal string, e.g. `'644'` or
  /// `'4755'` — the same convention `ContainerLease.putFile` uses, and for
  /// the same reason: Dart has no octal literal.
  final String mode;

  /// See this class's doc comment for why these must be numbers.
  final int uid;
  final int gid;
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

/// A user-defined network for containers that need to find each other by
/// name.
///
/// rig prefixes the name it actually gives Docker, so `ContainerNetwork('app')`
/// becomes `rig-app`. A bare `app` could silently reuse a network the caller,
/// or something like Compose, already made for its own purposes; the prefix
/// keeps rig's networks visibly its own, which is also what makes them safe
/// for `rig prune` to find and remove.
final class ContainerNetwork {
  const ContainerNetwork(this.name, {this.alias});

  /// rig creates `rig-<name>` if it does not exist.
  final String name;

  /// What containers on this network call this one.
  ///
  /// Docker assigns this container's own name (something like
  /// `hungry_mendeleev`), which nothing in a spec can predict. The alias is
  /// the only name another container on the same network can be told to use
  /// in advance. Leaving it out means this container can still reach others
  /// by their alias, but nothing can reach *it* by name — only by an address
  /// no test can know ahead of time.
  final String? alias;

  /// The name Docker actually sees.
  String get dockerName => 'rig-$name';
}

/// Build the image from a Dockerfile instead of pulling it.
///
/// Const-constructible for the same reason [ContainerSpec] is: rig hashes
/// the spec, and the build context's own content — not just this value —
/// feeds that hash, folded in the same way a [Mount]'s content is.
final class ContainerBuild {
  const ContainerBuild({
    required this.context,
    this.dockerfile = 'Dockerfile',
    this.args = const {},
  });

  /// Directory sent to the daemon as the build context.
  ///
  /// If it contains a `.dockerignore`, rig interprets it client-side before
  /// sending anything — the daemon itself does not, so this is the only
  /// place exclusion happens. A pattern rig does not understand (currently
  /// only a character class like `[a-z]`) throws rather than being sent
  /// anyway.
  final String context;

  /// The Dockerfile's name, relative to [context].
  ///
  /// Always sent even if `.dockerignore` excludes it — Docker itself builds
  /// successfully in that case, so rig keeps this file in the context
  /// regardless, rather than send a request the daemon would reject.
  final String dockerfile;

  /// Build-time `ARG` values.
  final Map<String, String> args;
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
    this.files = const [],
    this.labels = const {},
    this.user,
    this.workingDir,
    this.privileged = false,
    this.networkMode,
    this.network,
    this.healthcheck,
    this.lifetime = Lifetime.shared,
    this.build,
  });

  /// Image reference including the tag, e.g. `postgres:16-alpine`.
  ///
  /// Doubles as the tag rig gives the built image when [build] is set —
  /// the same way `docker compose build` treats a service's `image:` as
  /// where its build ends up. [image] stays required either way, rather
  /// than becoming optional when [build] is present, to avoid a breaking
  /// change to every existing spec.
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

  /// Files written into the container between create and start — see
  /// [ContainerFile]'s doc comment for why this exists alongside [mounts]
  /// and `ContainerLease.putFile`.
  final List<ContainerFile> files;

  /// Labels for the caller's own use. rig adds its own on top and excludes
  /// these from the hash, so tagging a container never splits sharing.
  final Map<String, String> labels;

  final String? user;
  final String? workingDir;
  final bool privileged;

  /// A raw Docker network mode, e.g. `host` or `none`. Mutually exclusive
  /// with [network]: `normalizeSpec` throws if both are set.
  final String? networkMode;

  /// A network rig creates and connects this container to. Mutually
  /// exclusive with [networkMode].
  final ContainerNetwork? network;

  final Healthcheck? healthcheck;
  final Lifetime lifetime;

  /// Build [image] from a Dockerfile instead of pulling it. Null means pull.
  final ContainerBuild? build;

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
    List<ContainerFile>? files,
    Map<String, String>? labels,
    String? user,
    String? workingDir,
    bool? privileged,
    String? networkMode,
    ContainerNetwork? network,
    Healthcheck? healthcheck,
    Lifetime? lifetime,
    ContainerBuild? build,
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
      files: files ?? this.files,
      labels: labels ?? this.labels,
      user: user ?? this.user,
      workingDir: workingDir ?? this.workingDir,
      privileged: privileged ?? this.privileged,
      networkMode: networkMode ?? this.networkMode,
      network: network ?? this.network,
      healthcheck: healthcheck ?? this.healthcheck,
      lifetime: lifetime ?? this.lifetime,
      build: build ?? this.build,
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
///
/// Throws [ArgumentError] when both [ContainerSpec.networkMode] and
/// [ContainerSpec.network] are set. The check lives here rather than in
/// [ContainerSpec]'s constructor so a spec stays const-constructible; it runs
/// once, right before the spec is used, rather than at every place one is
/// declared.
NormalizedSpec normalizeSpec(ContainerSpec spec) {
  if (spec.networkMode != null && spec.network != null) {
    throw ArgumentError(
      'ContainerSpec.networkMode and ContainerSpec.network are mutually '
      'exclusive. networkMode is for raw Docker modes like "host" or '
      '"none"; network is for a user-defined network rig creates and '
      'connects this container to.',
    );
  }

  final sortedEnv = spec.env.keys.toList()..sort();
  final sortedPorts = spec.exposedPorts.toSet().toList()..sort();
  final sortedTmpfs = spec.tmpfs.toList()..sort();
  final sortedMounts = spec.mounts.toList()..sort(compareMounts);
  final network = spec.network;

  return NormalizedSpec([
    'image=${spec.image}',
    // Marks that this spec builds its image rather than pulling it, so a
    // spec that starts building under a tag someone else already pulled
    // (or vice versa) is never mistaken for "same image name, same
    // container". The build context's own content is folded into the hash
    // separately, by specHash, the same way a mount's content is.
    if (spec.build != null) 'build=true',
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
    // Named distinctly from the `network=` line above so the two can never
    // collide, even though the constructor never lets both appear together.
    // A different alias changes how other containers on the network address
    // this one, so it has to split the hash exactly like the name does.
    if (network != null) 'usernetwork.name=${network.name}',
    if (network?.alias != null) 'usernetwork.alias=${network!.alias}',
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
