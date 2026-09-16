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

  /// The last [createContainer] arguments, for assertions.
  ContainerSpec? lastCreatedSpec;
  Map<String, String>? lastCreatedLabels;

  /// The first host port handed out; incremented per published port.
  int nextHostPort = 40000;

  final Map<String, _FakeContainer> _containers = {};
  int _nextId = 1;

  /// Adds a container that already exists, as if a previous run left it.
  String addContainer({
    required Map<String, String> labels,
    String image = 'scratch:latest',
    String state = 'running',
    DateTime? created,
    Map<int, int> hostPorts = const {},
    List<HealthStatus> health = const [],
    String logs = '',
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
    _containers[id] = _FakeContainer(
      id: id,
      image: spec.image,
      running: false,
      state: 'created',
      labels: Map.of(labels),
      created: DateTime.utc(2026, 1, 1),
      hostPorts: {for (final port in spec.exposedPorts) port: nextHostPort++},
      health: spec.healthcheck == null ? [] : [HealthStatus.starting],
      logs: '',
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
  Future<void> stopContainer(
    String id, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    calls.add('stop:$id');
    _require(id)
      ..running = false
      ..state = 'exited';
  }

  @override
  Future<void> removeContainer(String id) async {
    calls.add('remove:$id');
    _containers.remove(id);
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

  /// Pops the next queued status, holding the last one once exhausted.
  HealthStatus nextHealth() {
    if (health.isEmpty) return HealthStatus.none;
    if (health.length == 1) return health.first;
    return health.removeAt(0);
  }
}
