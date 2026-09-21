import 'package:rig/module.dart';
import 'package:rig/rig.dart';

/// A name that could not be turned into a MySQL identifier.
final class UnsafeMySqlIdentifier extends RigException {
  const UnsafeMySqlIdentifier({required this.identifier, required this.reason});

  final String identifier;
  final String reason;

  @override
  String get message =>
      'Cannot use "$identifier" as a MySQL identifier: $reason. '
      'Pick a name without it.';
}

/// [identifier] wrapped in backticks, ready to appear in a statement.
///
/// A backtick inside is doubled, which is how MySQL escapes one. Three
/// things are refused outright rather than escaped: an empty name, because
/// nothing here ever legitimately wants one; and a line break or a NUL
/// byte, because nothing here needs either and a name carrying one makes
/// every error message that quotes the statement unreadable.
String mysqlIdentifier(String identifier) {
  if (identifier.isEmpty) {
    throw const UnsafeMySqlIdentifier(identifier: '', reason: 'it is empty');
  }
  if (identifier.contains('\n') || identifier.contains('\r')) {
    throw UnsafeMySqlIdentifier(
      identifier: identifier,
      reason: 'it contains a line break',
    );
  }
  if (identifier.contains('\u0000')) {
    throw UnsafeMySqlIdentifier(
      identifier: identifier,
      reason: 'it contains a NUL byte',
    );
  }
  return '`${identifier.replaceAll('`', '``')}`';
}

/// [value] as a MySQL string literal.
///
/// Both the quote and the backslash are doubled. The backslash needs it
/// because MySQL reads one inside a string literal as an escape character,
/// unlike the standard — a value ending in a backslash would otherwise
/// swallow the closing quote.
///
/// The two doublings run in a fixed order but do not depend on it: doubling a
/// backslash introduces no quote, and doubling a quote introduces no
/// backslash, so neither feeds the other. That stops holding the moment a
/// third character is added whose replacement contains a backslash or a
/// quote — at which point the order becomes load-bearing and this paragraph
/// is wrong.
String mysqlStringLiteral(String value) =>
    "'${value.replaceAll(r'\', r'\\').replaceAll("'", "''")}'";

/// Runs [sql] inside [containerId] as root and hands back what mysql said.
///
/// No shell. The statement is one argv entry, so nothing in it is
/// reinterpreted on the way: the backticks around an identifier would become
/// command substitution inside a shell's double quotes, and switching that
/// shell to single quotes would collide with the quotes around a string
/// literal. No quoting survives both, so the shell has to be absent rather
/// than worked around.
///
/// `-N -B` is the counterpart of psql's `-tAc`: no column names, tab
/// separated, one row per line.
Future<ExecResult> runMysql(
  DockerEngine engine,
  String containerId, {
  required String rootPassword,
  required String sql,
}) => engine.exec(containerId, [
  'mysql',
  '-uroot',
  // mysql takes the password joined to the flag; a space would make it read
  // the next argument as a database name and prompt for a password instead.
  '-p$rootPassword',
  '-N',
  '-B',
  '-e',
  sql,
]);
