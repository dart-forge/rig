import 'dart:io';

import 'package:rig/engine.dart';
import 'package:rig/fake_engine.dart';
import 'package:rig/rig.dart';
import 'package:rig_mysql/rig_mysql.dart';
import 'package:rig_mysql/src/testing.dart' show confirmAuthMode;
import 'package:test/test.dart';

final engine = FakeDockerEngine();
final tmp = Directory.systemTemp.createTempSync('rig_my_');

void main() {
  overrideEngine(engine);
  tearDownAll(() => tmp.deleteSync(recursive: true));

  group('a shared MySQL', () {
    final my = useMySql(
      stateDir: StateDir(tmp),
      isolation: MySqlIsolation.none,
    );

    test('is reachable by the time a test body runs', () {
      expect(my.port, greaterThan(1024));
      expect(my.url, startsWith('mysql://test:test@127.0.0.1:'));
      expect(my.database, 'test_db');
    });
  });

  group('native password confirms the stored password', () {
    final my = useMySql(
      auth: MySqlAuth.nativePassword,
      stateDir: StateDir(tmp),
      isolation: MySqlIsolation.none,
    );

    test('stores it again under the plugin that was asked for', () {
      // The image stored the password during initialisation, under whatever
      // the server default was then. Without this the connection would
      // succeed while never exercising mysql_native_password at all.
      //
      // Named in full rather than matching 'IDENTIFIED WITH': the group
      // above shares this engine and issues its own ALTER USER, so a loose
      // match would pass on that one and say nothing about this group.
      expect(
        engine.calls.where(
          (c) => c.contains('IDENTIFIED WITH mysql_native_password'),
        ),
        isNotEmpty,
      );
      expect(my.url, isNotEmpty);
    });
  });

  group('two suites on one container', () {
    final first = useMySql(stateDir: StateDir(tmp));
    final second = useMySql(stateDir: StateDir(tmp));

    test('each get their own database', () {
      expect(first.database, isNot(second.database));
      expect(first.database, startsWith('test_'));
      expect(second.database, startsWith('test_'));
    });

    test('and the same container', () {
      expect(first.container.containerId, second.container.containerId);
    });
  });

  group('isolation can be turned off', () {
    final my = useMySql(
      stateDir: StateDir(tmp),
      isolation: MySqlIsolation.none,
    );

    test('and then the container own database is used', () {
      expect(my.database, 'test_db');
    });
  });

  group('confirmAuthMode', () {
    late FakeDockerEngine fake;
    late String containerId;

    setUp(() {
      fake = FakeDockerEngine();
      containerId = fake.addContainer(labels: const {});
    });

    Future<void> confirm({
      MySqlAuth auth = MySqlAuth.cachingSha2,
      String user = 'test',
      String password = 'test',
    }) => confirmAuthMode(
      engine: fake,
      containerId: containerId,
      auth: auth,
      rootPassword: 'root',
      user: user,
      password: password,
    );

    String alterStatement() =>
        fake.calls.firstWhere((c) => c.contains('ALTER USER'));

    test('names the plugin the mode asks for', () async {
      await confirm();

      expect(
        alterStatement(),
        contains('IDENTIFIED WITH caching_sha2_password'),
      );
    });

    test('names the other plugin for the other mode', () async {
      await confirm(auth: MySqlAuth.nativePassword);

      expect(
        alterStatement(),
        contains('IDENTIFIED WITH mysql_native_password'),
      );
    });

    test('names the user and the wildcard host the image created', () async {
      // The entrypoint creates MYSQL_USER as 'name'@'%'; an ALTER USER that
      // named a different host would create a second account instead of
      // changing this one, and the test would authenticate as whichever the
      // server picked.
      await confirm();

      expect(alterStatement(), contains("ALTER USER 'test'@'%'"));
    });

    test(
      'a password containing a quote does not break the statement',
      () async {
        await confirm(password: "it's");

        expect(alterStatement(), contains("BY 'it''s'"));
      },
    );

    test(
      'a password ending in a backslash does not swallow the quote',
      () async {
        // MySQL reads a backslash inside a string literal as an escape
        // character, unlike the standard.
        await confirm(password: 'ends\\');

        expect(alterStatement(), contains(r"BY 'ends\\'"));
      },
    );

    test('reports its own failure as a RigException', () async {
      fake.onExec = (_) =>
          const ExecResult(exitCode: 1, output: 'ERROR 1524 (HY000)');

      await expectLater(
        confirm(),
        throwsA(
          isA<AuthConfirmationFailed>().having(
            (e) => e.message,
            'message',
            contains('1524'),
          ),
        ),
      );
    });

    test('explains that the mode would otherwise go unexercised', () async {
      // The failure a reader needs to understand is not "a statement
      // failed": it is that the container would authenticate with whatever
      // the image happened to store, and every assertion about the auth mode
      // would be meaningless. Other tests in this group already pin that the
      // plugin is named in the statement; this one pins the reason it might
      // not be loaded at all.
      fake.onExec = (_) =>
          const ExecResult(exitCode: 1, output: 'ERROR 1524 (HY000)');

      await expectLater(
        confirm(auth: MySqlAuth.nativePassword),
        throwsA(
          isA<AuthConfirmationFailed>().having(
            (e) => e.message,
            'message',
            contains('8.4'),
          ),
        ),
      );
    });
  });
}
