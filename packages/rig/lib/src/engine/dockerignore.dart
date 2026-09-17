import '../errors.dart';

/// One line of a `.dockerignore`, already validated and normalized.
///
/// [segments] is the pattern split on `/`, with a leading `/` or `./`
/// stripped and any trailing `/` dropped — the same shape a build-context
/// relative path is split into, so the two can be compared segment by
/// segment in [isExcludedByDockerignore].
final class DockerignoreRule {
  const DockerignoreRule({required this.negated, required this.segments});

  /// True for a line starting with `!`.
  final bool negated;

  /// Never empty: a pattern that normalizes to nothing is dropped by
  /// [parseDockerignore] rather than kept as a rule that matches everything.
  final List<String> segments;
}

/// Parses `.dockerignore` content into ordered rules.
///
/// Order matters: [isExcludedByDockerignore] applies rules in this order and
/// lets the last one that matches a given path decide its fate, exactly the
/// way `docker build` does.
///
/// Comment lines (`#`), blank lines, and surrounding whitespace are dropped.
/// A pattern containing `[` — a character class — is not interpreted:
/// silently ignoring it would risk sending a file the author meant to
/// exclude, which is the one failure this feature exists to prevent, so it
/// throws [DockerignorePatternNotSupported] instead. The exception carries
/// the 1-based line number and the offending pattern so the message can
/// point at exactly what could not be understood.
List<DockerignoreRule> parseDockerignore(String content) {
  final rules = <DockerignoreRule>[];
  final lines = content.split('\n');

  for (var i = 0; i < lines.length; i++) {
    final lineNumber = i + 1;
    var line = lines[i].trim();
    if (line.isEmpty || line.startsWith('#')) continue;

    var negated = false;
    if (line.startsWith('!')) {
      negated = true;
      line = line.substring(1).trim();
    }

    if (line.contains('[')) {
      throw DockerignorePatternNotSupported(line: lineNumber, pattern: line);
    }

    final segments = _normalizePatternPath(line)
        .split('/')
        .where((s) => s.isNotEmpty)
        .toList();
    if (segments.isEmpty) continue;

    rules.add(DockerignoreRule(negated: negated, segments: segments));
  }

  return rules;
}

/// Strips a leading `/` or `./` (repeated, so `/./a` and `//a` both become
/// `a`) and a single trailing `/`. What is left is relative to the build
/// context, matching how a [DockerignoreRule]'s segments compare against a
/// context-relative path.
String _normalizePatternPath(String raw) {
  var path = raw;
  while (path.startsWith('/')) {
    path = path.substring(1);
  }
  while (path.startsWith('./')) {
    path = path.substring(2);
  }
  if (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return path;
}

/// Same normalization [parseDockerignore] applies to a pattern, exposed so
/// [listBuildContext] can normalize `build.dockerfile` the same way before
/// comparing it against a context-relative path — `./Dockerfile` and
/// `Dockerfile` must name the same file for the "always include" rule to
/// find it.
String normalizeContextRelativePath(String raw) => _normalizePatternPath(raw);

/// Whether [pathSegments] — a build-context-relative path, already split on
/// `/`, directory trailing slash already stripped — is excluded by [rules].
///
/// Two rules from the brief, both load-bearing:
///
/// - **Last match wins.** Every rule is checked, in file order; whichever
///   one last matched decides the outcome. This is why the loop below never
///   returns early on a match — an early return would make whichever rule
///   type (exclude or include) happens to run first always win, which is a
///   different and wrong policy.
/// - **A directory match excludes everything under it.** There is no
///   separate "is this an ancestor" check: matching is tried against every
///   non-empty prefix of [pathSegments], not just the full path, so a rule
///   that matches `sub/deep` also matches `sub/deep/d.log` by matching the
///   `sub/deep` prefix of it.
bool isExcludedByDockerignore(
  List<String> pathSegments,
  List<DockerignoreRule> rules,
) {
  var excluded = false;
  for (final rule in rules) {
    if (_matchesSomePrefix(rule.segments, pathSegments)) {
      excluded = !rule.negated;
    }
  }
  return excluded;
}

bool _matchesSomePrefix(List<String> pattern, List<String> path) {
  for (var length = 1; length <= path.length; length++) {
    if (_matchSegments(pattern, 0, path, 0, length)) return true;
  }
  return false;
}

/// Matches [pattern] against exactly the first [pathLength] elements of
/// [path], consuming both fully — the only way a match counts, so `*.log`
/// (one segment) can never match `sub/c.log` (two segments): there is no
/// pattern segment left to account for `c.log` once `*` is spent on `sub`,
/// and `*` does not itself cross the `/` between them.
///
/// `**` is the one pattern segment allowed to consume zero or more path
/// segments, which is what lets it — and only it — cross that boundary.
bool _matchSegments(
  List<String> pattern,
  int patternIndex,
  List<String> path,
  int pathIndex,
  int pathLength,
) {
  if (patternIndex == pattern.length) return pathIndex == pathLength;

  final segment = pattern[patternIndex];
  if (segment == '**') {
    for (var next = pathIndex; next <= pathLength; next++) {
      if (_matchSegments(pattern, patternIndex + 1, path, next, pathLength)) {
        return true;
      }
    }
    return false;
  }

  if (pathIndex == pathLength) return false;
  if (!_segmentGlobMatches(segment, path[pathIndex])) return false;
  return _matchSegments(
    pattern,
    patternIndex + 1,
    path,
    pathIndex + 1,
    pathLength,
  );
}

final Map<String, RegExp> _segmentRegexCache = {};

/// Matches one path component against one pattern component: `*` for any
/// run of characters (including none), `?` for exactly one, everything else
/// literal. Neither wildcard can match `/` because there is none in either
/// argument — a path is already split into components before this runs.
bool _segmentGlobMatches(String patternSegment, String pathSegment) {
  final regExp = _segmentRegexCache.putIfAbsent(patternSegment, () {
    final buffer = StringBuffer('^');
    for (final char in patternSegment.split('')) {
      if (char == '*') {
        buffer.write('.*');
      } else if (char == '?') {
        buffer.write('.');
      } else {
        buffer.write(RegExp.escape(char));
      }
    }
    buffer.write(r'$');
    return RegExp(buffer.toString());
  });
  return regExp.hasMatch(pathSegment);
}
