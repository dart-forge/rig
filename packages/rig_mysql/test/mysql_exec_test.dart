import 'package:rig/fake_engine.dart';
import 'package:rig/module.dart';
import 'package:rig_mysql/src/mysql_exec.dart';
import 'package:test/test.dart';

void main() {
  group('mysqlIdentifier', () {
    test('wraps the name in backticks', () {
      expect(mysqlIdentifier('test_db'), '`test_db`');
    });

    test('doubles a backtick inside, which is how MySQL escapes one', () {
      expect(mysqlIdentifier('we`ird'), '`we``ird`');
    });

    test('refuses an empty name', () {
      expect(() => mysqlIdentifier(''), throwsA(isA<UnsafeMySqlIdentifier>()));
    });

    test('refuses a line break', () {
      // Nothing here needs one, and a name carrying one makes every error
      // message that quotes the statement unreadable.
      expect(
        () => mysqlIdentifier('a\nb'),
        throwsA(isA<UnsafeMySqlIdentifier>()),
      );
    });

    test('refuses a NUL byte', () {
      expect(
        () => mysqlIdentifier('a\u0000b'),
        throwsA(isA<UnsafeMySqlIdentifier>()),
      );
    });

    test('says what is wrong with the name it refused', () {
      // The caller picked this name; the message has to point at it rather
      // than at MySQL's eventual complaint.
      expect(
        () => mysqlIdentifier('a\nb'),
        throwsA(
          isA<UnsafeMySqlIdentifier>().having(
            (e) => e.message,
            'message',
            contains('line break'),
          ),
        ),
      );
    });
  });

  group('mysqlStringLiteral', () {
    test('wraps the value in single quotes', () {
      expect(mysqlStringLiteral('test'), "'test'");
    });

    test('doubles a single quote inside', () {
      expect(mysqlStringLiteral("it's"), "'it''s'");
    });

    test('doubles a backslash, which MySQL treats as an escape', () {
      // Unlike the standard, MySQL reads a backslash inside a string literal
      // as an escape character. A value ending in one would otherwise
      // swallow the closing quote.
      expect(mysqlStringLiteral(r'ends\'), r"'ends\\'");
    });

    test('escapes the backslash before the quote, not after', () {
      // The other order turns one quote into a backslash followed by two,
      // which is a different string.
      expect(mysqlStringLiteral("a\\'b"), r"'a\\''b'");
    });
  });

  group('runMysql', () {
    late FakeDockerEngine engine;
    late String containerId;
    late List<String> captured;

    setUp(() {
      engine = FakeDockerEngine();
      containerId = engine.addContainer(labels: const {});
      captured = [];
      engine.onExec = (command) {
        captured = command;
        return const ExecResult(exitCode: 0, output: '');
      };
    });

    test('hands the statement over as one argument', () async {
      await runMysql(
        engine,
        containerId,
        rootPassword: 'root',
        sql: 'SELECT 1',
      );

      expect(captured, contains('SELECT 1'));
    });

    test('does not go through a shell', () async {
      // A shell would reinterpret the statement: the backticks around an
      // identifier become command substitution inside double quotes, and
      // switching to single quotes collides with the quotes around a string
      // literal. No quoting survives both, so the shell has to be absent
      // rather than worked around.
      const grant = "GRANT ALL ON `db`.* TO 'test'@'%'";

      await runMysql(engine, containerId, rootPassword: 'root', sql: grant);

      expect(captured.first, 'mysql');
      expect(captured, isNot(contains('sh')));
      expect(captured, isNot(contains('-c')));
      expect(captured, contains(grant));
    });

    test('runs as root with the password attached to the flag', () async {
      // mysql takes the password joined to -p; a space would make it read
      // the next argument as a database name and prompt for a password.
      await runMysql(
        engine,
        containerId,
        rootPassword: 'hunter2',
        sql: 'SELECT 1',
      );

      expect(captured, contains('-uroot'));
      expect(captured, contains('-phunter2'));
    });

    test('asks for rows without column names, one per line', () async {
      // The counterpart of psql's -tAc: callers split the output on
      // newlines and expect nothing but values.
      await runMysql(
        engine,
        containerId,
        rootPassword: 'root',
        sql: 'SELECT 1',
      );

      expect(captured, containsAll(['-N', '-B']));
    });

    test('hands back what mysql said', () async {
      engine.onExec = (_) =>
          const ExecResult(exitCode: 1, output: 'ERROR 1044 (42000)');

      final result = await runMysql(
        engine,
        containerId,
        rootPassword: 'root',
        sql: 'SELECT 1',
      );

      expect(result.exitCode, 1);
      expect(result.output, contains('1044'));
    });
  });
}
