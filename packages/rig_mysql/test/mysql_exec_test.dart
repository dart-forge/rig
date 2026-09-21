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

    test('doubles both when a value carries a quote and a backslash', () {
      // Both are doubled, and the two doublings do not interfere: doubling a
      // backslash introduces no quote and doubling a quote introduces no
      // backslash. So this value comes out the same whichever runs first,
      // which means the order is not what this test pins. What it pins is
      // that neither doubling was dropped.
      expect(mysqlStringLiteral("a\\'b"), r"'a\\''b'");
    });
  });

  group('mysqlCommand', () {
    // user and password are deliberately different strings throughout this
    // group, so an assertion checking one cannot pass by coincidentally
    // matching the other.
    const user = 'alice';
    const password = 'hunter2';

    test(
      'argv is sh, its script, then \$0 and the three positional values',
      () {
        final command = mysqlCommand(
          user: user,
          password: password,
          sql: 'SELECT 1',
        );

        expect(command, [
          'sh',
          '-c',
          r'MYSQL_PWD="$1" exec mysql -u"$2" -N -B -e "$3"',
          'sh',
          password,
          user,
          'SELECT 1',
        ]);
      },
    );

    test('the statement reaches the argv exactly once, as its own entry — '
        'pasting it into the script instead would make it disappear from '
        'here', () {
      const sql = "SELECT 'it''s' FROM `t`";
      final command = mysqlCommand(user: user, password: password, sql: sql);

      expect(command.where((arg) => arg == sql), hasLength(1));
      expect(command.last, sql);
    });

    test('the script does not contain the statement — a future edit that '
        'pasted it in would corrupt the script the moment the statement '
        'carried a quote or a backtick, which is exactly what it is not '
        'allowed to do', () {
      const sql = "SELECT 'it''s' FROM `t`";
      final command = mysqlCommand(user: user, password: password, sql: sql);

      expect(command[2], isNot(contains(sql)));
      expect(command[2], isNot(contains("'")));
      expect(command[2], isNot(contains('`')));
    });

    test('the script references the statement positionally, as \$3 — this '
        'is what the previous test alone could not tell apart from a '
        'script that dropped the statement entirely rather than expanding '
        'it', () {
      final command = mysqlCommand(
        user: user,
        password: password,
        sql: 'SELECT 1',
      );

      expect(command[2], contains(r'"$3"'));
    });

    test(
      'the password travels through MYSQL_PWD, never as a -p flag — a -p '
      'flag is what makes the client write the warning to stderr that '
      'Docker\'s exec API merges into the same output every caller reads',
      () {
        final command = mysqlCommand(
          user: user,
          password: password,
          sql: 'SELECT 1',
        );

        expect(command[2], contains('MYSQL_PWD='));
        expect(command[2], isNot(contains('-p')));
      },
    );

    test('the user reaches the client as -u"\$2", positionally rather than '
        'pasted into the script', () {
      final command = mysqlCommand(
        user: user,
        password: password,
        sql: 'SELECT 1',
      );

      expect(command[2], contains(r'-u"$2"'));
      expect(command[2], isNot(contains(user)));
    });

    test('still asks for rows without column names, one per line', () {
      // The counterpart of psql's -tAc: callers split the output on
      // newlines and expect nothing but values.
      final command = mysqlCommand(
        user: user,
        password: password,
        sql: 'SELECT 1',
      );

      expect(command[2], contains('-N'));
      expect(command[2], contains('-B'));
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

    test(
      'delegates to mysqlCommand as root, with the given password',
      () async {
        await runMysql(
          engine,
          containerId,
          rootPassword: 'hunter2',
          sql: 'SELECT 1',
        );

        expect(
          captured,
          mysqlCommand(user: 'root', password: 'hunter2', sql: 'SELECT 1'),
        );
      },
    );

    test('hands back the ExecResult unchanged', () async {
      engine.onExec = (_) =>
          const ExecResult(exitCode: 1, output: 'ERROR 1044 (42000)');

      final result = await runMysql(
        engine,
        containerId,
        rootPassword: 'root',
        sql: 'SELECT 1',
      );

      expect(result.exitCode, 1);
      expect(result.output, 'ERROR 1044 (42000)');
    });
  });
}
