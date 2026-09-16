import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'container_spec.dart';

/// Mounted files up to this size are hashed by content; larger ones by size
/// and mtime.
const int defaultMaxMountBytes = 1 << 20;

/// The key rig uses to decide whether a container it already runs can serve
/// this spec.
///
/// Mounted paths are folded in by *content*, not by path. A spec that mounts
/// a certificate must stop matching the running container the moment that
/// certificate is replaced — otherwise the old one keeps serving and the
/// failure has no visible cause.
String specHash(
  ContainerSpec spec, {
  int maxMountBytes = defaultMaxMountBytes,
}) {
  final lines = [
    // The canonical `mount=` line carries the raw host path, which is not
    // part of what the container ends up seeing. Drop it here and rely on
    // the content-keyed lines below instead, so identical content mounted
    // from a different host path still hashes the same.
    ...normalizeSpec(spec).canonicalLines
        .where((line) => !line.startsWith('mount=')),
    ..._mountContentLines(spec, maxMountBytes),
  ];
  final digest = sha256.convert(utf8.encode(_unambiguous(lines)));
  return digest.toString().substring(0, 16);
}

/// Join [lines] so that no set of line contents can produce the same string
/// as a different list of lines.
///
/// A plain newline join is ambiguous. A spec with a single env value that
/// contains a newline produces the same text as a spec with two env entries,
/// so two different specs would hash alike and a suite would silently be
/// handed the wrong container — the worst thing this library can do. Writing
/// each line's byte length in front of it removes the ambiguity without
/// relying on an escape scheme being complete.
String _unambiguous(List<String> lines) {
  final buffer = StringBuffer();
  for (final line in lines) {
    buffer
      ..write(utf8.encode(line).length)
      ..write(':')
      ..write(line)
      ..write('\n');
  }
  return buffer.toString();
}

List<String> _mountContentLines(ContainerSpec spec, int maxBytes) {
  final sorted = spec.mounts.toList()
    ..sort((a, b) => a.containerPath.compareTo(b.containerPath));

  return [
    for (final mount in sorted)
      'mount.content=${mount.containerPath}:${mount.readOnly ? 'ro' : 'rw'}'
          '=${_digestOf(mount.hostPath, maxBytes)}',
  ];
}

String _digestOf(String hostPath, int maxBytes) {
  final asFile = File(hostPath);
  if (asFile.existsSync()) return _fileDigest(asFile, maxBytes);

  final asDir = Directory(hostPath);
  if (asDir.existsSync()) return _dirDigest(asDir, maxBytes);

  // Do not silently treat a missing source as "no content": if it appears
  // later, that is a different container.
  return 'absent';
}

String _fileDigest(File file, int maxBytes) {
  final stat = file.statSync();
  if (stat.size > maxBytes) {
    return 'size:${stat.size}:mtime:${stat.modified.microsecondsSinceEpoch}';
  }
  return sha256.convert(file.readAsBytesSync()).toString();
}

String _dirDigest(Directory dir, int maxBytes) {
  final entries =
      dir
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .map((f) => (rel: p.relative(f.path, from: dir.path), file: f))
          .toList()
        ..sort((a, b) => a.rel.compareTo(b.rel));

  final parts = [
    for (final e in entries) '${e.rel}=${_fileDigest(e.file, maxBytes)}',
  ];
  return sha256.convert(utf8.encode(parts.join('\n'))).toString();
}
