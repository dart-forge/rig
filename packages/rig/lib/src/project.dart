import 'dart:io';

import 'package:path/path.dart' as p;

/// The pubspec name of the package the tests belong to, for labelling.
///
/// Walks up from [from] to the nearest pubspec. Returns empty rather than
/// throwing: a missing name makes `rig ls` less informative, which is not
/// worth failing a test run over.
String currentProjectName({Directory? from}) {
  var dir = from ?? Directory.current;

  while (true) {
    final pubspec = File(p.join(dir.path, 'pubspec.yaml'));
    if (pubspec.existsSync()) {
      final name = _readName(pubspec);
      if (name != null) return name;
    }

    final parent = dir.parent;
    if (parent.path == dir.path) return '';
    dir = parent;
  }
}

/// Only a `name:` at the start of a line is the package name; the same key
/// appears nested under dependencies.
String? _readName(File pubspec) {
  try {
    final match = RegExp(
      r'^name:\s*([A-Za-z0-9_]+)',
      multiLine: true,
    ).firstMatch(pubspec.readAsStringSync());
    return match?.group(1);
  } on FileSystemException {
    return null;
  }
}
