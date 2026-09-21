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
/// A backtick inside is doubled, which is how MySQL escapes one. A line break
/// or a NUL byte is refused instead: nothing here needs either, and a name
/// carrying one makes every error message that quotes the statement
/// unreadable.
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
/// The backslash is doubled before the quote is: unlike the standard, MySQL
/// reads a backslash inside a string literal as an escape character, so a
/// value ending in one would otherwise swallow the closing quote. Doing it in
/// the other order would turn one quote into a backslash followed by two.
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
