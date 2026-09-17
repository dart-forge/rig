import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../errors.dart';

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
/// daemon, validating as it goes.
///
/// Shared by the tar writer and `specHash`'s context digest, so the same
/// checks run whether or not a build is actually about to happen: a spec
/// with a bad build context should fail to hash, not just fail to build.
///
/// Throws [DockerignoreNotSupported] when the context has a `.dockerignore`
/// (rig does not interpret it, and silently sending everything anyway risks
/// shipping something the author meant to exclude), [SymlinkInBuildContext]
/// for any symlink (following or skipping it would both build a different
/// image than the one on disk), and [BuildContextPathTooLong] for a path
/// that cannot fit in ustar's `name`/`prefix` fields.
List<ContextEntry> listBuildContext(Directory contextDir) {
  final dockerignore = File(p.join(contextDir.path, '.dockerignore'));
  if (dockerignore.existsSync()) {
    throw DockerignoreNotSupported(contextPath: contextDir.path);
  }

  final entries = <ContextEntry>[];
  for (final entity in contextDir.listSync(
    recursive: true,
    followLinks: false,
  )) {
    final rel = p
        .relative(entity.path, from: contextDir.path)
        .split(Platform.pathSeparator)
        .join('/');

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
/// Only regular files and directories are written — everything a Docker
/// build context legitimately needs, and everything [listBuildContext]
/// allows through. File modes are carried over from the filesystem so that
/// an executable script an image `RUN`s stays executable.
Uint8List buildContextTar(Directory contextDir) {
  final out = BytesBuilder(copy: false);

  for (final entry in listBuildContext(contextDir)) {
    final split = _splitUstarPath(entry.relativePath);
    final size = entry.isDirectory ? 0 : entry.source!.lengthSync();

    out.add(
      _header(
        name: split.name,
        prefix: split.prefix,
        mode: entry.mode,
        size: size,
        typeflag: entry.isDirectory ? '5' : '0',
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
}) {
  final buf = Uint8List(_headerSize);

  _writeAscii(buf, 0, 100, name);
  _writeOctal(buf, 100, 8, mode);
  _writeOctal(buf, 108, 8, 0); // uid
  _writeOctal(buf, 116, 8, 0); // gid
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
