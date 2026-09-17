import '../errors.dart';
import '../spec/container_spec.dart';
import 'docker_engine.dart';

/// An in-memory [DockerEngine] for tests.
///
/// Published so that rig modules and `rig_cli` can test against it. It models
/// only what rig asks of Docker: create, start, inspect, list, stop, remove,
/// pull, logs.
final class FakeDockerEngine implements DockerEngine {
  FakeDockerEngine({
    this.versionInfo = const EngineVersion(
      version: '29.5.3',
      apiVersion: '1.54',
      minApiVersion: '1.40',
    ),
  });

  /// Every call, in order: `create`, `start:<id>`, `stop:<id>`, ...
  final List<String> calls = [];

  /// Images that [imageExists] reports as present.
  final Set<String> images = {};

  EngineVersion versionInfo;

  /// When set, [ping] throws it.
  Object? pingError;

  /// When false, [pullImage] throws [ImagePullFailed].
  bool pullSucceeds = true;
  String pullFailureDetail = 'manifest unknown';

  /// When false, [buildImage] throws [ImageBuildFailed].
  bool buildSucceeds = true;
  String buildFailureDetail = 'RUN exit 1';

  /// The arguments of the last [buildImage] call, for assertions.
  ContainerBuild? lastBuild;
  String? lastBuildTag;

  /// When set, [removeContainer] throws it instead of removing anything.
  Object? removeError;

  /// Answers [exec]. Defaults to success with no output.
  ///
  /// The fake runs nothing, so a test states what the command would have done.
  ExecResult Function(List<String> command) onExec = (_) =>
      const ExecResult(exitCode: 0, output: '');

  /// The last [createContainer] arguments, for assertions.
  ContainerSpec? lastCreatedSpec;
  Map<String, String>? lastCreatedLabels;

  /// The first host port handed out; incremented per published port.
  int nextHostPort = 40000;

  /// What a container created through [createContainer] reports for health,
  /// in order, holding the last value once exhausted.
  ///
  /// The fake does not run probes, so a test states what the probe would do.
  /// The default passes through `starting` once and then reports healthy,
  /// which is what Docker does when a probe starts succeeding. A test whose
  /// container must never become usable sets this to `[HealthStatus.starting]`
  /// so it stays there.
  List<HealthStatus> healthAfterCreate = const [
    HealthStatus.starting,
    HealthStatus.healthy,
  ];

  final Map<String, _FakeContainer> _containers = {};
  final Map<String, _FakeNetwork> _networksByName = {};
  int _nextId = 1;

  /// Adds a network as if a previous run left it, for tests that exercise
  /// `rig prune`'s network cleanup without going through [ensureNetwork] or
  /// [createContainer].
  String addNetwork({
    required String name,
    Map<String, String> labels = const {},
    List<String> connectedContainerIds = const [],
  }) {
    final net = _FakeNetwork(
      id: 'net${_nextId++}',
      name: name,
      labels: Map.of(labels),
    )..connectedContainerIds.addAll(connectedContainerIds);
    _networksByName[name] = net;
    return net.id;
  }

  /// Adds a container that already exists, as if a previous run left it.
  ///
  /// [network] is the Docker network *name* (the same string passed to
  /// [addNetwork]'s `name`), for a caller that wants [removeContainer] to
  /// free that network's active endpoint again, the way Docker would.
  String addContainer({
    required Map<String, String> labels,
    String image = 'scratch:latest',
    String state = 'running',
    DateTime? created,
    Map<int, int> hostPorts = const {},
    List<HealthStatus> health = const [],
    String logs = '',
    String? network,
  }) {
    final id = 'fake${_nextId++}';
    _containers[id] = _FakeContainer(
      id: id,
      image: image,
      running: state == 'running',
      state: state,
      labels: Map.of(labels),
      created: created ?? DateTime.utc(2026, 1, 1),
      hostPorts: Map.of(hostPorts),
      health: [...health],
      logs: logs,
      network: network,
    );
    return id;
  }

  /// Makes [inspectContainer] report [statuses] in order, then hold the last.
  void queueHealth(String id, List<HealthStatus> statuses) {
    _require(id).health = [...statuses];
  }

  void setLogs(String id, String logs) {
    _require(id).logs = logs;
  }

  @override
  Future<void> ping() async {
    calls.add('ping');
    if (pingError != null) throw pingError!;
  }

  @override
  Future<EngineVersion> version() async {
    calls.add('version');
    return versionInfo;
  }

  @override
  Future<bool> imageExists(String image) async => images.contains(image);

  @override
  Future<void> pullImage(String image) async {
    calls.add('pull:$image');
    if (!pullSucceeds) {
      throw ImagePullFailed(image: image, detail: pullFailureDetail);
    }
    images.add(image);
  }

  @override
  Future<void> buildImage(ContainerBuild build, String tag) async {
    calls.add('build:$tag');
    lastBuild = build;
    lastBuildTag = tag;
    if (!buildSucceeds) {
      throw ImageBuildFailed(tag: tag, detail: buildFailureDetail);
    }
    images.add(tag);
  }

  @override
  Future<List<ContainerSummary>> listContainers({
    Map<String, List<String>> filters = const {},
    bool all = true,
  }) async {
    calls.add('list');
    return _containers.values
        .where((c) => _matches(c, filters, all))
        .map(
          (c) => ContainerSummary(
            id: c.id,
            image: c.image,
            state: c.running ? 'running' : c.state,
            labels: Map.unmodifiable(c.labels),
            created: c.created,
            names: ['/${c.id}'],
          ),
        )
        .toList();
  }

  @override
  Future<String> createContainer(
    ContainerSpec spec,
    Map<String, String> labels,
  ) async {
    calls.add('create');
    lastCreatedSpec = spec;
    lastCreatedLabels = Map.of(labels);

    final id = 'fake${_nextId++}';
    final networkName = spec.network?.dockerName;
    if (networkName != null) {
      _networksByName
          .putIfAbsent(
            networkName,
            () => _FakeNetwork(id: 'net${_nextId++}', name: networkName),
          )
          .connectedContainerIds
          .add(id);
    }
    _containers[id] = _FakeContainer(
      id: id,
      image: spec.image,
      running: false,
      state: 'created',
      labels: Map.of(labels),
      created: DateTime.utc(2026, 1, 1),
      hostPorts: {for (final port in spec.exposedPorts) port: nextHostPort++},
      health: spec.healthcheck == null ? [] : [...healthAfterCreate],
      logs: '',
      network: networkName,
    );
    return id;
  }

  @override
  Future<void> startContainer(String id) async {
    calls.add('start:$id');
    _require(id)
      ..running = true
      ..state = 'running';
  }

  @override
  Future<ContainerInspect> inspectContainer(String id) async {
    final c = _require(id);
    return ContainerInspect(
      id: c.id,
      running: c.running,
      health: c.nextHealth(),
      hostPorts: Map.unmodifiable(c.hostPorts),
      labels: Map.unmodifiable(c.labels),
      created: c.created,
    );
  }

  @override
  Future<String> logTail(String id, {int lines = 50}) async =>
      _require(id).logs;

  @override
  Future<String> logs(String id) async => _require(id).logs;

  @override
  Future<ExecResult> exec(String id, List<String> command) async {
    calls.add('exec:$id:${command.join(' ')}');
    _require(id);
    return onExec(command);
  }

  @override
  Future<void> stopContainer(
    String id, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    calls.add('stop:$id');
    _require(id)
      ..running = false
      ..state = 'exited';
  }

  @override
  Future<void> removeContainer(String id) async {
    calls.add('remove:$id');
    final error = removeError;
    if (error != null) throw error;
    final removed = _containers.remove(id);
    // Docker disconnects a removed container from every network it was on;
    // mirroring that here is what lets a fake-backed prune test see a
    // network's active endpoints drop to zero once its container is gone.
    final networkName = removed?.network;
    if (networkName != null) {
      _networksByName[networkName]?.connectedContainerIds.remove(id);
    }
  }

  @override
  Future<void> removeImage(String tag) async {
    calls.add('removeImage:$tag');
    images.remove(tag);
  }

  @override
  Future<void> ensureNetwork(String name, Map<String, String> labels) async {
    calls.add('ensureNetwork:$name');
    _networksByName.putIfAbsent(
      name,
      () => _FakeNetwork(
        id: 'net${_nextId++}',
        name: name,
        labels: Map.of(labels),
      ),
    );
  }

  @override
  Future<List<NetworkSummary>> listNetworks({
    Map<String, List<String>> filters = const {},
  }) async {
    calls.add('listNetworks');
    return _networksByName.values
        .where((n) => _matchesNetworkFilter(n, filters))
        .map(
          (n) => NetworkSummary(
            id: n.id,
            name: n.name,
            hasActiveEndpoints: n.connectedContainerIds.isNotEmpty,
          ),
        )
        .toList();
  }

  @override
  Future<bool> removeNetwork(String id) async {
    calls.add('removeNetwork:$id');
    _FakeNetwork? found;
    for (final n in _networksByName.values) {
      if (n.id == id) {
        found = n;
        break;
      }
    }
    if (found == null) return true; // already gone
    if (found.connectedContainerIds.isNotEmpty) return false;
    _networksByName.remove(found.name);
    return true;
  }

  bool _matchesNetworkFilter(
    _FakeNetwork n,
    Map<String, List<String>> filters,
  ) {
    for (final wanted in filters['label'] ?? const <String>[]) {
      final parts = wanted.split('=');
      final key = parts.first;
      if (parts.length == 1) {
        if (!n.labels.containsKey(key)) return false;
      } else if (n.labels[key] != parts.sublist(1).join('=')) {
        return false;
      }
    }
    return true;
  }

  @override
  Future<void> close() async => calls.add('close');

  _FakeContainer _require(String id) {
    final c = _containers[id];
    if (c == null) throw StateError('no such fake container: $id');
    return c;
  }

  bool _matches(_FakeContainer c, Map<String, List<String>> filters, bool all) {
    if (!all && !c.running) return false;

    for (final wanted in filters['label'] ?? const <String>[]) {
      final parts = wanted.split('=');
      final key = parts.first;
      if (parts.length == 1) {
        if (!c.labels.containsKey(key)) return false;
      } else if (c.labels[key] != parts.sublist(1).join('=')) {
        return false;
      }
    }

    final states = filters['status'];
    if (states != null && !states.contains(c.running ? 'running' : c.state)) {
      return false;
    }
    return true;
  }
}

final class _FakeContainer {
  _FakeContainer({
    required this.id,
    required this.image,
    required this.running,
    required this.state,
    required this.labels,
    required this.created,
    required this.hostPorts,
    required this.health,
    required this.logs,
    this.network,
  });

  final String id;
  final String image;
  bool running;
  String state;
  final Map<String, String> labels;
  final DateTime created;
  final Map<int, int> hostPorts;
  List<HealthStatus> health;
  String logs;

  /// The Docker network name (already `rig-`-prefixed) this container was
  /// created on, or null when its spec had none.
  final String? network;

  /// Pops the next queued status, holding the last one once exhausted.
  HealthStatus nextHealth() {
    if (health.isEmpty) return HealthStatus.none;
    if (health.length == 1) return health.first;
    return health.removeAt(0);
  }
}

final class _FakeNetwork {
  _FakeNetwork({required this.id, required this.name, this.labels = const {}});

  final String id;
  final String name;
  final Map<String, String> labels;

  /// Ids of containers currently attached, i.e. what backs
  /// [NetworkSummary.hasActiveEndpoints].
  final Set<String> connectedContainerIds = {};
}
