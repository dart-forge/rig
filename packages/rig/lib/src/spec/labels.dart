import 'container_spec.dart';

/// Present on every container rig creates. `rig prune` treats it as the
/// permission to delete.
const String rigMarkerLabel = 'org.rig';

/// The spec hash. This is the search key for sharing.
const String rigHashLabel = 'org.rig.hash';

/// `shared` or `dedicated`.
const String rigLifetimeLabel = 'org.rig.lifetime';

/// The pubspec name of the package whose tests created this.
const String rigProjectLabel = 'org.rig.project';

/// A short, human-readable description for `rig ls`.
const String rigSummaryLabel = 'org.rig.summary';

/// The labels rig puts on a container it creates.
///
/// Docker has no way to change a label afterwards, so nothing that rig will
/// later want to rewrite belongs here. That is why a failed readiness mark
/// lives in the state directory instead, and why there is no creation
/// timestamp: Docker reports `Created` itself.
Map<String, String> buildRigLabels({
  required ContainerSpec spec,
  required String hash,
  required String project,
}) {
  return {
    // The caller's labels go first so rig's own always win.
    ...spec.labels,
    rigMarkerLabel: '1',
    rigHashLabel: hash,
    rigLifetimeLabel: spec.lifetime.name,
    rigProjectLabel: project,
    rigSummaryLabel: summarizeSpec(spec),
  };
}

const int _summaryBudget = 200;

/// A one-line description of [spec] for human eyes.
///
/// Env *keys* only: a summary shows up in `rig ls` and in shared terminals,
/// and values are often credentials.
String summarizeSpec(ContainerSpec spec) {
  final parts = [
    spec.image,
    if (spec.exposedPorts.isNotEmpty)
      'ports=${(spec.exposedPorts.toSet().toList()..sort()).join(',')}',
    if (spec.env.isNotEmpty)
      'env=${(spec.env.keys.toList()..sort()).join(',')}',
  ];
  final summary = parts.join(' ');
  if (summary.length <= _summaryBudget) return summary;
  return '${summary.substring(0, _summaryBudget - 1)}…';
}

/// What rig can read back off a container it finds.
final class RigLabels {
  const RigLabels({
    required this.hash,
    required this.lifetime,
    required this.project,
    required this.summary,
  });

  final String hash;
  final Lifetime lifetime;
  final String project;
  final String summary;

  /// Read rig's labels off [labels], or null when rig did not make this
  /// container.
  static RigLabels? tryParse(Map<String, String> labels) {
    if (labels[rigMarkerLabel] != '1') return null;

    final hash = labels[rigHashLabel];
    if (hash == null || hash.isEmpty) return null;

    return RigLabels(
      hash: hash,
      lifetime: _parseLifetime(labels[rigLifetimeLabel]),
      project: labels[rigProjectLabel] ?? '',
      summary: labels[rigSummaryLabel] ?? '',
    );
  }

  /// An unrecognised value reads as dedicated: rig must never hand a
  /// container to a second suite unless it is certain sharing was intended.
  static Lifetime _parseLifetime(String? value) => switch (value) {
    'shared' => Lifetime.shared,
    _ => Lifetime.dedicated,
  };
}
