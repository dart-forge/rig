import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../engine/tar.dart';
import '../errors.dart';
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
///
/// The canonical lines carry a mount's container path and access mode but not
/// its host path, so nothing here needs to filter them: the two halves of a
/// mount's identity are declared in one place each.
String specHash(
  ContainerSpec spec, {
  int maxMountBytes = defaultMaxMountBytes,
}) {
  final lines = [
    ...normalizeSpec(spec).canonicalLines,
    ..._mountContentLines(spec, maxMountBytes),
    ..._fileLines(spec.files),
    ..._buildContextLines(spec.build, maxMountBytes),
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
  final sorted = spec.mounts.toList()..sort(compareMounts);

  return [
    for (final mount in sorted)
      'mount.content=${mount.containerPath}=${_digestOf(mount.hostPath, maxBytes)}',
  ];
}

/// Folds `ContainerSpec.files` in by path, mode, uid, gid and content, the
/// same reason [_mountContentLines] folds a mount's content in: a file that
/// is part of what the container starts up with must stop matching a
/// container running with different content, ownership, or mode.
///
/// Sorted by path first, so declaration order cannot move the hash — the
/// same reasoning [_mountContentLines] applies via [compareMounts]. Sorting
/// first is also what makes two files sharing a path detectable as
/// *adjacent* entries, which is what the throw below checks: which one
/// would actually reach the container is an accident of list order, not a
/// choice anyone made, so this refuses to pick a winner silently.
List<String> _fileLines(List<ContainerFile> files) {
  final sorted = files.toList()..sort((a, b) => a.path.compareTo(b.path));

  for (var i = 1; i < sorted.length; i++) {
    if (sorted[i].path == sorted[i - 1].path) {
      throw DuplicateContainerFilePath(path: sorted[i].path);
    }
  }

  return [
    for (final file in sorted)
      'file=${file.path}=mode:${file.mode}:uid:${file.uid}:gid:${file.gid}:'
          '${sha256.convert(file.content).toString()}',
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

/// Folds a build context in by content, the same reason and the same way
/// [_mountContentLines] folds a mount in: a spec that keeps building under
/// the same tag but with different Dockerfile input must stop matching a
/// container built from the old one.
///
/// Files are read through [listBuildContext], which validates the context
/// (rejects symlinks and paths ustar cannot represent, and throws on a
/// `.dockerignore` pattern it does not understand) as a side effect — so a
/// spec with a broken build context fails to hash, not just fails to build.
/// It also applies `.dockerignore`, so only *included* files reach this
/// list: an excluded file never reaches the daemon, so it must not affect
/// whether a spec still matches a running container.
///
/// `.dockerignore` itself is excluded from this list on purpose, even though
/// [listBuildContext] still sends it in the tar (same as `docker build`
/// does). Only the *set of files it causes to be included* should move the
/// hash: rewriting which patterns are listed changes that set and the hash
/// moves with it; rewriting the file without changing what it excludes
/// (e.g. adding a comment) leaves the daemon building the exact same image,
/// so hashing the ignore file's own content would move the hash for no
/// reason a running container's identity depends on.
///
/// Sorted already by that call; each file's mode is included alongside its
/// content because an executable bit is exactly the kind of change that
/// must not be silently absorbed into "same container".
List<String> _buildContextLines(ContainerBuild? build, int maxBytes) {
  if (build == null) return const [];

  final sortedArgKeys = build.args.keys.toList()..sort();
  final files = listBuildContext(
    Directory(build.context),
    dockerfile: build.dockerfile,
  ).where((e) => !e.isDirectory && e.relativePath != '.dockerignore');

  return [
    'build.dockerfile=${build.dockerfile}',
    for (final key in sortedArgKeys) 'build.arg=$key=${build.args[key]}',
    for (final file in files)
      'build.file=${file.relativePath}='
          'mode:${file.mode}:${_fileDigest(file.source!, maxBytes)}',
  ];
}

String _fileDigest(File file, int maxBytes) {
  final stat = file.statSync();
  if (stat.size > maxBytes) {
    return 'size:${stat.size}:mtime:${stat.modified.microsecondsSinceEpoch}';
  }
  return sha256.convert(file.readAsBytesSync()).toString();
}

/// Symlinks are not followed: doing so would make the hash depend on
/// whatever the link points at, which can live outside the mount entirely.
/// A directory with no files in it (or none under the byte limit) walks to
/// an empty list of entries and so contributes a fixed digest of its own —
/// still distinct from [_digestOf]'s `absent` for a source that does not
/// exist, but the same for every empty directory, however it got that way.
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
