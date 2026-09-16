/// How many rig containers `useContainer` warns above, unless told otherwise.
const int defaultWarnAboveContainers = 20;

/// The threshold `useContainer`'s piling-up warning compares against.
///
/// A free function over [environment] rather than a parameter of
/// `useContainer`: the threshold is a machine-wide concern, not a per-suite
/// one, and the "already warned" flag it feeds is per isolate — so a value
/// set by one test file's call never reached the next file's call anyway.
/// `RIG_WARN_ABOVE` applies to every file in the run instead.
///
/// Not exported: reach it directly by importing this file where a test
/// needs to, the way `lock.dart`'s internals are reached.
int warnThreshold(Map<String, String> environment) {
  final raw = environment['RIG_WARN_ABOVE'];
  if (raw == null) return defaultWarnAboveContainers;
  return int.tryParse(raw) ?? defaultWarnAboveContainers;
}
