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

/// The argv that runs [sql] inside a container as [user].
///
/// A shell, deliberately, and the data as positional parameters rather than
/// pasted into the script. Two reasons, and neither is avoidable:
///
/// The password travels in the environment because with `-p` on the command
/// line the client writes a warning to stderr, and Docker's exec API merges
/// stderr into stdout — so every caller reading the output would have to
/// strip a line that is not data. It also keeps the password out of the
/// client's own process title.
///
/// The statement travels as `$3` because pasting it into the script cannot
/// be made safe: inside the script's double quotes a backtick-quoted
/// identifier becomes command substitution, and switching the script to
/// single quotes collides with the quotes around a string literal. A value
/// the shell expands from a positional parameter is not re-scanned for
/// either, so the statement arrives exactly as written.
///
/// `-N -B` is the counterpart of psql's `-tAc`: no column names, tab
/// separated, one row per line.
List<String> mysqlCommand({
  required String user,
  required String password,
  required String sql,
}) => [
  'sh',
  '-c',
  r'MYSQL_PWD="$1" exec mysql -u"$2" -N -B -e "$3"',
  // Consumed by the shell as $0, so the statement lands on $3.
  'sh',
  password,
  user,
  sql,
];

/// Runs [sql] inside [containerId] as root and hands back what mysql said.
Future<ExecResult> runMysql(
  DockerEngine engine,
  String containerId, {
  required String rootPassword,
  required String sql,
}) => engine.exec(
  containerId,
  mysqlCommand(user: 'root', password: rootPassword, sql: sql),
);
