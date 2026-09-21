import 'dart:io';

import 'package:path/path.dart' as p;

import '../lease/state_dir.dart';

/// How long a suite's marker is trusted before the suite is presumed gone.
///
/// A day, against test runs measured in minutes. A marker younger than this
/// protects what it claims unconditionally — no age or connection check can
/// tell a suite sitting between two connections from an abandoned one, which
/// is why the marker exists. Older than this and the suite is not coming
/// back.
const Duration defaultMarkerStaleAfter = Duration(hours: 24);

/// Where the marker recording that [resource] inside [containerId] belongs to
/// a suite that is still running is kept.
///
/// A file rather than an in-memory flag: `dart test` gives every suite file
/// its own isolate, and isolates share no memory, so the filesystem is the
/// one channel every isolate in a run can see.
///
/// [kind] namespaces one module's markers from another's, and [resource] is
/// whatever that module claims inside the container — a database name, an
/// index. `rig prune` sweeps `markers/*/<containerId>` without knowing any
/// kind, so a new module needs no change there.
File suiteMarkerFile({
  required StateDir stateDir,
  required String kind,
  required String containerId,
  required String resource,
}) => File(p.join(stateDir.markerDir(kind).path, containerId, resource));

/// Whether [marker] still says a running suite holds what it claims.
///
/// False when the marker is absent: a resource nobody marked is nobody's.
/// False when the marker is older than [markerStaleAfter]: teardown is what
/// removes a marker, so one this old belongs to a run that never got there.
///
/// The threshold itself counts as still claiming. Being wrong in the other
/// direction takes a resource away from a run that is still going.
bool markerStillClaims(
  File marker, {
  required DateTime now,
  Duration markerStaleAfter = defaultMarkerStaleAfter,
}) {
  if (!marker.existsSync()) return false;
  final age = now.toUtc().difference(marker.lastModifiedSync().toUtc());
  return age <= markerStaleAfter;
}
