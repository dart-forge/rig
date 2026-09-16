import 'package:rig/engine.dart';

/// Print the containers rig is holding.
Future<int> runLs({
  required DockerEngine engine,
  required void Function(String) out,
  required DateTime now,
}) async {
  final containers = await rigContainers(engine);

  if (containers.isEmpty) {
    out('No containers held by rig.');
    return 0;
  }

  final rows = [
    ['HASH', 'SUMMARY', 'STATE', 'LIFETIME', 'AGE', 'PROJECT'],
    for (final c
        in containers.toList()..sort((a, b) => b.created.compareTo(a.created)))
      _row(c, now),
  ];

  for (final line in _renderTable(rows)) {
    out(line);
  }
  return 0;
}

List<String> _row(ContainerSummary c, DateTime now) {
  final labels = RigLabels.tryParse(c.labels);
  // RigLabels.tryParse reads a missing summary label as '', not null, so
  // `?? c.image` never catches it. An empty summary is exactly as
  // uninformative as a missing one.
  final summary = labels?.summary ?? '';
  return [
    labels?.hash ?? '?',
    summary.isEmpty ? c.image : summary,
    c.state,
    labels?.lifetime.name ?? '?',
    formatAge(now.difference(c.created)),
    labels?.project ?? '',
  ];
}

/// Age rather than a timestamp: the question a reader has is "is this old
/// enough to delete", not "when exactly was it made".
String formatAge(Duration age) {
  if (age.inDays > 0) return '${age.inDays}d';
  if (age.inHours > 0) return '${age.inHours}h';
  if (age.inMinutes > 0) return '${age.inMinutes}m';
  return 'just now';
}

Iterable<String> _renderTable(List<List<String>> rows) {
  final widths = List.generate(
    rows.first.length,
    (i) => rows.map((r) => r[i].length).reduce((a, b) => a > b ? a : b),
  );
  return rows.map(
    (row) => [
      for (var i = 0; i < row.length; i++)
        i == row.length - 1 ? row[i] : row[i].padRight(widths[i]),
    ].join('  ').trimRight(),
  );
}
