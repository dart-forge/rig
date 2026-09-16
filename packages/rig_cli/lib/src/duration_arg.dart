/// Parse `7d`, `12h`, `30m`, or a bare number of days.
Duration parseDurationArg(String raw) {
  final match = RegExp(r'^(\d+)([dhm]?)$').firstMatch(raw.trim());
  if (match == null) {
    throw FormatException(
      'Expected a duration like 7d, 12h or 30m (a bare number means days), '
      'got: $raw',
    );
  }

  final amount = int.parse(match.group(1)!);
  return switch (match.group(2)) {
    'h' => Duration(hours: amount),
    'm' => Duration(minutes: amount),
    _ => Duration(days: amount),
  };
}
