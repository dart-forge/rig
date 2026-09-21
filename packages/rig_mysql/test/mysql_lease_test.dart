import 'package:rig/fake_engine.dart';
import 'package:rig/module.dart';
import 'package:rig/rig.dart';
import 'package:rig_mysql/rig_mysql.dart';
import 'package:test/test.dart';

void main() {
  late FakeDockerEngine engine;

  setUp(() {
    engine = FakeDockerEngine();
    overrideEngine(engine);
  });

  ContainerLease leaseFor({Map<int, int> ports = const {3306: 33061}}) {
    // FakeDockerEngine.exec refuses an id it never created, and
    // flushAuthCache goes through exec — so the lease has to name a
    // container the fake actually knows. The Postgres sibling gets away
    // with a literal id because nothing in it ever calls exec.
    final containerId = engine.addContainer(labels: const {});

    return ContainerLease.of(
      engine,
      AcquiredContainer(
        containerId: containerId,
        host: '127.0.0.1',
        hostPorts: ports,
        lifetime: Lifetime.shared,
        reused: false,
        hash: 'h',
      ),
    );
  }

  MySqlLease leaseWith({
    String user = 'alice',
    String password = 'hunter2',
    String rootPassword = 'admin',
    Map<int, int> ports = const {3306: 33061},
  }) => MySqlLease(
    container: leaseFor(ports: ports),
    user: user,
    password: password,
    rootPassword: rootPassword,
  );

  test('builds a url a MySQL client will accept', () {
    final my = leaseWith()..bindDatabase('shop');

    expect(my.url, 'mysql://alice:hunter2@127.0.0.1:33061/shop');
  });

  test('exposes the parts as well as the url', () {
    final my = leaseWith(ports: const {3306: 35000})..bindDatabase('shop');

    expect(my.host, '127.0.0.1');
    expect(my.port, 35000);
    expect(my.user, 'alice');
    expect(my.password, 'hunter2');
    expect(my.database, 'shop');
  });

  test('exposes the administrative password', () {
    // MYSQL_USER is not a superuser, unlike the user the Postgres image
    // creates. A test that needs to create a schema, grant a privilege or
    // read mysql.user has to be root, and without this it has no way to.
    expect(leaseWith(rootPassword: 'admin').rootPassword, 'admin');
  });

  test('escapes credentials that would otherwise break the url', () {
    final my = leaseWith(user: 'al ice', password: 'p@ss:word/x')
      ..bindDatabase('shop');

    expect(Uri.parse(my.url).userInfo, 'al%20ice:p%40ss%3Aword%2Fx');
    expect(Uri.parse(my.url).port, 33061);
  });

  test('refuses to name a database before one has been chosen', () {
    // With the default isolation the database does not exist until setUpAll
    // creates it, so there is no value that would be honest to hand back.
    // Returning the container's own database in the meantime would be worse:
    // a helper that captured it at declaration time would go on writing into
    // the shared database without ever being told isolation had stopped
    // applying.
    expect(() => leaseWith().database, throwsA(isA<LeaseNotBound>()));
  });

  group('flushAuthCache', () {
    test('clears the cache as root', () async {
      late List<String> captured;
      engine.onExec = (command) {
        captured = command;
        return const ExecResult(exitCode: 0, output: '');
      };

      await leaseWith(rootPassword: 'admin').flushAuthCache();

      // The password travels through MYSQL_PWD, as its own positional
      // argument, not as a -p flag — see mysqlCommand.
      expect(captured, contains('admin'));
      expect(captured, isNot(contains('-padmin')));
      expect(captured, contains('FLUSH PRIVILEGES'));
    });

    test('throws when the server refused', () async {
      // A silently failed flush would leave the cache warm, and a test
      // asserting the full authentication path would pass against the fast
      // one without any sign of it.
      engine.onExec = (_) =>
          const ExecResult(exitCode: 1, output: 'ERROR 1227 (42000)');

      await expectLater(
        leaseWith().flushAuthCache(),
        throwsA(isA<AuthCacheNotFlushed>()),
      );
    });

    test('says what the server said when it refused', () async {
      engine.onExec = (_) =>
          const ExecResult(exitCode: 1, output: 'ERROR 1227 (42000)');

      await expectLater(
        leaseWith().flushAuthCache(),
        throwsA(
          isA<AuthCacheNotFlushed>().having(
            (e) => e.message,
            'message',
            contains('1227'),
          ),
        ),
      );
    });
  });
}
