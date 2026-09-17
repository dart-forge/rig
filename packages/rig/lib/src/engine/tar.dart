import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../errors.dart';
import 'dockerignore.dart';

/// A validated entry of a Docker build context: a regular file or a
/// directory, never a symlink, with a path short enough for ustar.
///
/// [listBuildContext] is the only place these get built, which is what makes
/// "validated" true — nothing else constructs one.
final class ContextEntry {
  ContextEntry.file(this.relativePath, this.mode, File file)
    : isDirectory = false,
      source = file;

  ContextEntry.directory(this.relativePath, this.mode)
    : isDirectory = true,
      source = null;

  /// Forward-slash-separated, relative to the context root. Directories end
  /// with `/`.
  final String relativePath;

  /// POSIX permission bits (including setuid/setgid/sticky), read straight
  /// off the filesystem. The whole reason this type exists rather than
  /// `FileSystemEntity` is to carry this alongside the entry once, rather
  /// than re-stating it everywhere the mode is needed.
  final int mode;

  final bool isDirectory;

  /// Null for a directory.
  final File? source;
}

/// ustar's two path fields hold at most this many bytes combined.
const int _maxUstarPathBytes = 255;

/// Lists the files and directories a build context would send to the
/// daemon, validating and `.dockerignore`-filtering as it goes.
///
/// Shared by the tar writer and `specHash`'s context digest, so the same
/// checks run whether or not a build is actually about to happen: a spec
/// with a bad build context should fail to hash, not just fail to build.
///
/// If [contextDir] has a `.dockerignore`, every entry is checked against it
/// (see [isExcludedByDockerignore]) and excluded ones are dropped before
/// validation — a symlink or an over-long path inside an excluded directory
/// must not block a build that would never have sent it anyway. [dockerfile]
/// is the context-relative path named by `build.dockerfile`; when given, the
/// file at that path is always kept regardless of what `.dockerignore` says,
/// because the daemon special-cases the Dockerfile the same way and a build
/// missing it would break outright. Pass nothing for a call that is not
/// about a build (`ContainerLease.copyInto`'s directory case) — there is no
/// Dockerfile to protect there.
///
/// Throws [DockerignorePatternNotSupported] for a `.dockerignore` line rig
/// does not interpret, [SymlinkInBuildContext] for any symlink that survives
/// filtering (following or skipping it would both build a different image
/// than the one on disk), and [BuildContextPathTooLong] for a path that
/// cannot fit in ustar's `name`/`prefix` fields.
List<ContextEntry> listBuildContext(
  Directory contextDir, {
  String? dockerfile,
}) {
  final dockerignoreFile = File(p.join(contextDir.path, '.dockerignore'));
  final rules = dockerignoreFile.existsSync()
      ? parseDockerignore(dockerignoreFile.readAsStringSync())
      : const <DockerignoreRule>[];
  final keptPath = dockerfile == null
      ? null
      : normalizeContextRelativePath(dockerfile);

  final entries = <ContextEntry>[];
  for (final entity in contextDir.listSync(
    recursive: true,
    followLinks: false,
  )) {
    final rel = p
        .relative(entity.path, from: contextDir.path)
        .split(Platform.pathSeparator)
        .join('/');

    if (rel != keptPath && rules.isNotEmpty) {
      final segments = rel.split('/');
      if (isExcludedByDockerignore(segments, rules)) continue;
    }

    if (entity is Link) {
      throw SymlinkInBuildContext(path: rel);
    } else if (entity is File) {
      _checkPathLength(rel);
      entries.add(
        ContextEntry.file(rel, entity.statSync().mode & 0xFFF, entity),
      );
    } else if (entity is Directory) {
      final dirRel = '$rel/';
      _checkPathLength(dirRel);
      entries.add(
        ContextEntry.directory(dirRel, entity.statSync().mode & 0xFFF),
      );
    }
  }

  // Sorted so that a hash folding these in does not depend on the
  // filesystem's own, unspecified listing order.
  entries.sort((a, b) => a.relativePath.compareTo(b.relativePath));
  return entries;
}

void _checkPathLength(String relativePath) {
  if (utf8.encode(relativePath).length > _maxUstarPathBytes) {
    throw BuildContextPathTooLong(path: relativePath);
  }
}

/// Writes [contextDir] as a minimal ustar archive, suitable for
/// `POST /build`'s request body.
///
/// [dockerfile] should be `build.dockerfile` — see [listBuildContext] for
/// why passing it matters even when the Dockerfile happens to be excluded
/// by `.dockerignore`.
///
/// Only regular files and directories are written — everything a Docker
/// build context legitimately needs, and everything [listBuildContext]
/// allows through. File modes are carried over from the filesystem so that
/// an executable script an image `RUN`s stays executable.
Uint8List buildContextTar(Directory contextDir, {String? dockerfile}) =>
    _archiveFromEntries(
      listBuildContext(contextDir, dockerfile: dockerfile),
      uid: 0,
      gid: 0,
    );

/// Writes [hostDir]'s contents — not the directory itself — as a ustar
/// archive, for `PUT /containers/{id}/archive` (`ContainerLease.copyInto`).
///
/// Reuses [listBuildContext]'s validation (no symlink, no over-long path) —
/// a copy-in has the same reasons to reject those that a build context
/// does. No `dockerfile` is passed: this is not a build, so there is
/// nothing to always keep, but a `.dockerignore` that happens to sit in
/// [hostDir] is still honored the same way, rather than special-cased away.
/// [uid]/[gid] are written into every entry's header, which is the whole
/// point of `copyInto` taking them — see [ContainerLease.putFile]'s doc
/// comment for why that matters.
Uint8List directoryArchive(
  Directory hostDir, {
  required int uid,
  required int gid,
}) => _archiveFromEntries(listBuildContext(hostDir), uid: uid, gid: gid);

/// Writes [content] as a single-entry ustar archive, for `PUT
/// /containers/{id}/archive` when the caller has bytes in hand rather than
/// a file already on disk — `ContainerLease.putFile`'s case. [path] is the
/// entry's name inside the archive (typically just a basename: the
/// destination directory is named by the PUT request's own `path` query
/// parameter, not by anything in the archive).
Uint8List singleFileArchive({
  required String path,
  required List<int> content,
  required int mode,
  required int uid,
  required int gid,
}) {
  final split = _splitUstarPath(path);
  final out = BytesBuilder(copy: false);
  out.add(
    _header(
      name: split.name,
      prefix: split.prefix,
      mode: mode,
      size: content.length,
      typeflag: '0',
      uid: uid,
      gid: gid,
    ),
  );
  out.add(Uint8List.fromList(content));
  final padding = _paddingFor(content.length);
  if (padding > 0) out.add(Uint8List(padding));
  out.add(Uint8List(1024));
  return out.toBytes();
}

/// Builds the archive for `ContainerLease.copyInto` when the host side is a
/// single file rather than a directory: [directoryArchive] only handles the
/// directory case, so `copyInto` picks between the two based on what
/// [hostPath] actually is.
Uint8List hostPathArchive(
  String hostPath, {
  required int uid,
  required int gid,
}) {
  final type = FileSystemEntity.typeSync(hostPath);
  if (type == FileSystemEntityType.directory) {
    return directoryArchive(Directory(hostPath), uid: uid, gid: gid);
  }
  if (type == FileSystemEntityType.file) {
    final file = File(hostPath);
    return singleFileArchive(
      path: p.basename(hostPath),
      content: file.readAsBytesSync(),
      mode: file.statSync().mode & 0xFFF,
      uid: uid,
      gid: gid,
    );
  }
  throw ArgumentError('hostPath is neither a file nor a directory: $hostPath');
}

Uint8List _archiveFromEntries(
  List<ContextEntry> entries, {
  required int uid,
  required int gid,
}) {
  final out = BytesBuilder(copy: false);

  for (final entry in entries) {
    final split = _splitUstarPath(entry.relativePath);
    final size = entry.isDirectory ? 0 : entry.source!.lengthSync();

    out.add(
      _header(
        name: split.name,
        prefix: split.prefix,
        mode: entry.mode,
        size: size,
        typeflag: entry.isDirectory ? '5' : '0',
        uid: uid,
        gid: gid,
      ),
    );

    if (!entry.isDirectory) {
      final data = entry.source!.readAsBytesSync();
      out.add(data);
      final padding = _paddingFor(data.length);
      if (padding > 0) out.add(Uint8List(padding));
    }
  }

  // Two zero-filled 512-byte blocks mark the end of the archive. Without
  // them the daemon treats the stream as a truncated, broken tar.
  out.add(Uint8List(1024));
  return out.toBytes();
}

/// Rig's own mode strings, as taken by `ContainerLease.putFile`: 3 or 4
/// octal digits, e.g. `'644'` or `'4755'`. Dart has no octal literal, and
/// spelling the same value as `0x1A4` is not something anyone would
/// recognize as a permission bit pattern; a string read as octal is the
/// readable middle ground. Anything that is not 3-4 octal digits — `'999'`,
/// `'abc'`, an empty string — throws [InvalidFileMode] rather than being
/// coerced into whatever `int.parse` would make of it.
int parseFileMode(String mode) {
  if (!RegExp(r'^[0-7]{3,4}$').hasMatch(mode)) {
    throw InvalidFileMode(mode: mode);
  }
  return int.parse(mode, radix: 8);
}

int _paddingFor(int contentLength) {
  final remainder = contentLength % 512;
  return remainder == 0 ? 0 : 512 - remainder;
}

/// Splits [relativePath] into ustar's `name` (100 bytes) and `prefix` (155
/// bytes) fields.
///
/// A path that already fits in `name` alone gets an empty prefix. A longer
/// one is split at the rightmost `/` that leaves both fields within their
/// limits — the algorithm ustar itself specifies. [listBuildContext] has
/// already rejected anything over 255 bytes total, but that alone does not
/// guarantee a split exists (a single path component longer than 100 bytes
/// has nowhere to break), so this still throws [BuildContextPathTooLong] when
/// no valid split is found.
({String name, String prefix}) _splitUstarPath(String relativePath) {
  if (relativePath.length <= 100) {
    return (name: relativePath, prefix: '');
  }

  // Scans from the end so the first match found is the rightmost valid
  // split — the shortest possible `name`. Starting at a fixed offset based
  // only on `name`'s limit (as if the rightmost slash were always the one
  // that matters) would skip slashes that sit closer to the end of the
  // path, which is exactly the split this is supposed to prefer.
  for (var i = relativePath.length - 1; i >= 0; i--) {
    if (relativePath[i] != '/') continue;
    final prefix = relativePath.substring(0, i);
    final name = relativePath.substring(i + 1);
    if (prefix.length <= 155 && name.length <= 100) {
      return (name: name, prefix: prefix);
    }
  }

  throw BuildContextPathTooLong(path: relativePath);
}

// ---- ustar header ----

const int _headerSize = 512;

Uint8List _header({
  required String name,
  required String prefix,
  required int mode,
  required int size,
  required String typeflag,
  required int uid,
  required int gid,
}) {
  final buf = Uint8List(_headerSize);

  _writeAscii(buf, 0, 100, name);
  _writeOctal(buf, 100, 8, mode);
  _writeOctal(buf, 108, 8, uid);
  _writeOctal(buf, 116, 8, gid);
  _writeOctal(buf, 124, 12, size);
  _writeOctal(buf, 136, 12, 0); // mtime: content is what rig hashes, not time
  // chksum (148, 8 bytes) is filled with spaces while the sum is computed.
  for (var i = 148; i < 156; i++) {
    buf[i] = 0x20;
  }
  buf[156] = typeflag.codeUnitAt(0); // typeflag
  _writeAscii(
    buf,
    157,
    100,
    '',
  ); // linkname: always empty, symlinks are rejected
  _writeAscii(buf, 257, 6, 'ustar'); // magic ("ustar\0")
  buf[263] = 0x30; // version "00"
  buf[264] = 0x30;
  _writeAscii(buf, 265, 32, ''); // uname
  _writeAscii(buf, 297, 32, ''); // gname
  _writeOctal(buf, 329, 8, 0); // devmajor
  _writeOctal(buf, 337, 8, 0); // devminor
  _writeAscii(buf, 345, 155, prefix);
  // bytes 500-511 are the ustar padding, left zero.

  var sum = 0;
  for (final byte in buf) {
    sum += byte;
  }
  _writeChecksum(buf, sum);

  return buf;
}

void _writeAscii(Uint8List buf, int offset, int fieldLength, String value) {
  final bytes = ascii.encode(value);
  if (bytes.length > fieldLength) {
    // listBuildContext / _splitUstarPath must have already rejected
    // anything that would land here; this is a defensive final check.
    throw ArgumentError('"$value" does not fit in $fieldLength bytes');
  }
  buf.setRange(offset, offset + bytes.length, bytes);
  // The rest of the field is already zero (Uint8List's default), which is
  // exactly the NUL padding ustar text fields want.
}

/// Writes [value] as a NUL-terminated, zero-padded octal string filling
/// [fieldLength] bytes (so a 12-byte field holds 11 octal digits + NUL).
void _writeOctal(Uint8List buf, int offset, int fieldLength, int value) {
  final digits = fieldLength - 1;
  final octal = value.toRadixString(8).padLeft(digits, '0');
  if (octal.length > digits) {
    throw ArgumentError('$value does not fit in $digits octal digits');
  }
  for (var i = 0; i < digits; i++) {
    buf[offset + i] = octal.codeUnitAt(i);
  }
  buf[offset + digits] = 0;
}

/// The checksum field's own format differs from every other numeric field:
/// 6 octal digits, then a NUL, then a space — not a NUL alone.
void _writeChecksum(Uint8List buf, int sum) {
  final octal = sum.toRadixString(8).padLeft(6, '0');
  for (var i = 0; i < 6; i++) {
    buf[148 + i] = octal.codeUnitAt(i);
  }
  buf[148 + 6] = 0;
  buf[148 + 7] = 0x20;
}

// ---- ustar reader ----
//
// Written for `ContainerLease.getFile`, which needs to read what `GET
// /containers/{id}/archive` sends back. Understands exactly what the
// writers above produce: a `name`/`prefix` pair, an octal `size`, a
// `typeflag`, and content padded to the next 512-byte boundary. That is
// also what Docker's own daemon writes for a plain file or directory, which
// is the whole point — see the integration test that feeds this a tar the
// real daemon produced, not just one this file wrote itself.

/// One entry read back out of a ustar archive.
final class TarEntry {
  const TarEntry({
    required this.name,
    required this.typeflag,
    required this.content,
  });

  /// `prefix/name` joined back together, exactly as [buildContextTar] and
  /// friends split it going the other way.
  final String name;

  /// `'0'` (or the historical NUL byte some writers use) for a regular
  /// file, `'5'` for a directory.
  final String typeflag;

  final Uint8List content;

  bool get isDirectory => typeflag == '5';

  bool get isRegularFile => typeflag == '0' || typeflag == '\x00';
}

/// Reads every entry out of a ustar archive.
///
/// Stops at the first zero-filled header, which is how [buildContextTar]
/// and friends (and Docker itself) mark the end of the archive — including
/// a truncated one that runs out of bytes before finding it.
List<TarEntry> readTarEntries(Uint8List tar) {
  final entries = <TarEntry>[];
  var offset = 0;

  while (offset + _headerSize <= tar.length && !_isZeroBlock(tar, offset)) {
    final header = tar.sublist(offset, offset + _headerSize);
    offset += _headerSize;

    final name = _readAscii(header, 0, 100);
    final prefix = _readAscii(header, 345, 155);
    final size = _readOctal(header, 124, 12);
    final typeflag = String.fromCharCode(header[156]);

    if (offset + size > tar.length) {
      throw ArgumentError(
        'truncated tar: entry "$name" claims $size bytes past offset '
        '$offset, but the archive is only ${tar.length} bytes',
      );
    }
    final content = Uint8List.fromList(tar.sublist(offset, offset + size));
    offset += size + _paddingFor(size);

    entries.add(
      TarEntry(
        name: prefix.isEmpty ? name : '$prefix/$name',
        typeflag: typeflag,
        content: content,
      ),
    );
  }

  return entries;
}

/// Reads an archive expected to hold exactly one regular file — what
/// `GET /containers/{id}/archive?path=<file>` sends back for a file path.
///
/// Throws [UnexpectedArchiveContents] for anything else. Most commonly that
/// is a directory: Docker archives one as multiple entries (itself plus
/// whatever it contains) rather than the single entry a file produces, and
/// silently returning the first entry would hide that [requestedPath]
/// named something other than the single file the caller asked for.
Uint8List readSingleFileArchive(
  Uint8List tar, {
  required String requestedPath,
}) {
  final entries = readTarEntries(tar);
  if (entries.length == 1 && entries.single.isRegularFile) {
    return entries.single.content;
  }
  throw UnexpectedArchiveContents(
    requestedPath: requestedPath,
    entryNames: [for (final e in entries) e.name],
  );
}

bool _isZeroBlock(Uint8List tar, int offset) {
  for (var i = offset; i < offset + _headerSize; i++) {
    if (tar[i] != 0) return false;
  }
  return true;
}

String _readAscii(Uint8List buf, int offset, int length) {
  var end = offset;
  final limit = offset + length;
  while (end < limit && buf[end] != 0) {
    end++;
  }
  return ascii.decode(buf.sublist(offset, end));
}

int _readOctal(Uint8List buf, int offset, int length) {
  final text = _readAscii(buf, offset, length).trim();
  return text.isEmpty ? 0 : int.parse(text, radix: 8);
}
