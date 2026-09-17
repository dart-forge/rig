import 'docker_engine.dart';

/// Reads `GET /containers/{id}/json`.
ContainerInspect parseInspect(Map<String, Object?> json) {
  final state = json['State'] as Map<String, Object?>? ?? const {};
  final config = json['Config'] as Map<String, Object?>? ?? const {};
  final network = json['NetworkSettings'] as Map<String, Object?>? ?? const {};

  return ContainerInspect(
    id: json['Id'] as String? ?? '',
    running: state['Running'] == true,
    health: parseHealthStatus(state['Health']),
    hostPorts: parseHostPorts(network['Ports']),
    labels: _stringMap(config['Labels']),
    created: _parseCreated(json['Created']),
  );
}

/// Reads one entry of `GET /containers/json`.
ContainerSummary parseSummary(Map<String, Object?> json) => ContainerSummary(
  id: json['Id'] as String? ?? '',
  image: json['Image'] as String? ?? '',
  state: json['State'] as String? ?? '',
  labels: _stringMap(json['Labels']),
  created: _parseCreatedSeconds(json['Created']),
  names: [for (final n in (json['Names'] as List? ?? const [])) n.toString()],
);

/// Reads one entry of `GET /networks`.
NetworkSummary parseNetworkSummary(Map<String, Object?> json) {
  final containers = json['Containers'];
  return NetworkSummary(
    id: json['Id'] as String? ?? '',
    name: json['Name'] as String? ?? '',
    hasActiveEndpoints: containers is Map && containers.isNotEmpty,
  );
}

/// Docker reports `none` for a container without a healthcheck, and an
/// unfamiliar value is treated the same way: rig must not read an unknown
/// state as ready.
HealthStatus parseHealthStatus(Object? health) {
  if (health is! Map) return HealthStatus.none;
  return switch (health['Status']) {
    'starting' => HealthStatus.starting,
    'healthy' => HealthStatus.healthy,
    'unhealthy' => HealthStatus.unhealthy,
    _ => HealthStatus.none,
  };
}

/// Container port to host port, from `NetworkSettings.Ports`.
///
/// Docker often publishes both an IPv6 and an IPv4 binding for one port, with
/// different host ports. rig connects over IPv4, so an IPv4 binding wins.
Map<int, int> parseHostPorts(Object? ports) {
  if (ports is! Map) return const {};

  final result = <int, int>{};
  for (final entry in ports.entries) {
    final containerPort = int.tryParse(entry.key.toString().split('/').first);
    if (containerPort == null) continue;

    final bindings = entry.value;
    if (bindings is! List || bindings.isEmpty) continue;

    final chosen = _preferIpv4(bindings);
    if (chosen != null) result[containerPort] = chosen;
  }
  return result;
}

int? _preferIpv4(List<Object?> bindings) {
  int? fallback;
  for (final binding in bindings) {
    if (binding is! Map) continue;
    final port = int.tryParse(binding['HostPort']?.toString() ?? '');
    if (port == null) continue;

    final ip = binding['HostIp']?.toString() ?? '';
    if (!ip.contains(':')) return port; // IPv4 or empty
    fallback ??= port;
  }
  return fallback;
}

Map<String, String> _stringMap(Object? raw) {
  if (raw is! Map) return const {};
  return {
    for (final e in raw.entries) e.key.toString(): e.value?.toString() ?? '',
  };
}

/// `Created` on inspect is an RFC 3339 string with nanosecond precision,
/// which DateTime.parse rejects, so the fraction is trimmed to microseconds.
DateTime _parseCreated(Object? raw) {
  if (raw is! String || raw.isEmpty) {
    return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  }
  final trimmed = raw.replaceFirstMapped(
    RegExp(r'\.(\d{1,9})'),
    (m) => '.${m.group(1)!.padRight(6, '0').substring(0, 6)}',
  );
  return DateTime.tryParse(trimmed)?.toUtc() ??
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
}

/// `Created` in a listing is unix seconds.
DateTime _parseCreatedSeconds(Object? raw) {
  final seconds = raw is int ? raw : int.tryParse(raw?.toString() ?? '') ?? 0;
  return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
}
