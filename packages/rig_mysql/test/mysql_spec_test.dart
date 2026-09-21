import 'package:rig/module.dart';
import 'package:rig/rig.dart';
import 'package:rig_mysql/rig_mysql.dart';
import 'package:test/test.dart';

String specHashOf(ContainerSpec s) => specHash(s);

void main() {
  test('runs the version asked for', () {
    expect(mysqlSpec().image, 'mysql:8.4');
    expect(mysqlSpec(version: '8.0').image, 'mysql:8.0');
  });

  test('carries the credentials as the official image expects them', () {
    final spec = mysqlSpec(
      user: 'alice',
      password: 'hunter2',
      rootPassword: 'admin',
      database: 'shop',
    );

    expect(spec.env['MYSQL_USER'], 'alice');
    expect(spec.env['MYSQL_PASSWORD'], 'hunter2');
    expect(spec.env['MYSQL_ROOT_PASSWORD'], 'admin');
    expect(spec.env['MYSQL_DATABASE'], 'shop');
  });

  test('publishes the MySQL port', () {
    expect(mysqlSpec().exposedPorts, [3306]);
  });

  test('keeps the data directory in memory', () {
    // Nothing here outlives the container, and initialisation is most of the
    // startup.
    expect(mysqlSpec().tmpfs, contains('/var/lib/mysql'));
  });

  test('probes over TCP, not the socket', () {
    // During initialisation the entrypoint runs a temporary server with
    // --skip-networking. Without naming 127.0.0.1 the probe can succeed
    // against that one and report ready while initialisation is still going.
    expect(mysqlSpec().healthcheck!.test.last, contains('-h 127.0.0.1'));
  });

  test('probes without credentials', () {
    // mysqladmin ping exits 0 even when the login is refused, because the
    // server answered — which is all this needs to know. Passing the
    // password would put it in the container's own process list for
    // nothing.
    final probe = mysqlSpec(
      user: 'zaphod',
      password: 'betelgeuse',
      rootPassword: 'hunter2',
    ).healthcheck!.test.last;

    expect(probe, isNot(contains('zaphod')));
    expect(probe, isNot(contains('betelgeuse')));
    expect(probe, isNot(contains('hunter2')));
    // And no credential flag at all, whatever it might carry. Anchored on a
    // word boundary because the tool is called mysqladmin — a bare search
    // for the letters would match its own name, which is the mistake this
    // test had in its first version.
    expect(probe, isNot(matches(RegExp(r'(^|\s)-[up]'))));
  });

  test('waits for the healthcheck rather than the port', () {
    // The port answers before the server will authenticate anyone.
    expect(mysqlSpec().waitFor, isA<HealthyWait>());
  });

  test('asks for no command when nothing needs a flag', () {
    // An empty command lets the image's own default run. Naming mysqld with
    // no arguments would work too, but saying nothing is the smaller claim.
    expect(mysqlSpec().command, isEmpty);
  });

  test('names mysqld first when there are flags to pass', () {
    // The official entrypoint treats a command starting with a flag as
    // arguments to its own default. Naming the binary is what the image's
    // documentation does, and it does not depend on that behaviour.
    final command = mysqlSpec(maxConnections: 50).command;

    expect(command.first, 'mysqld');
    expect(command, contains('--max-connections=50'));
  });

  test('carries the flag the auth mode needs', () {
    expect(
      mysqlSpec(auth: MySqlAuth.nativePassword).command,
      containsAllInOrder(['mysqld', '--loose-mysql-native-password=ON']),
    );
  });

  test('the two auth modes hash differently', () {
    // Today they differ only because nativePassword happens to need a
    // server flag that cachingSha2 does not — cachingSha2 contributes no
    // flag of its own. That is accidental: a future mode needing no flag
    // either would hash the same as cachingSha2, and two suites asking for
    // different plugins would then be handed the same container. Each
    // suite's setUpAll re-stores the password under its own plugin, so
    // whichever ran last would silently decide what both suites actually
    // authenticate with. This pins the two modes apart regardless of why.
    expect(
      specHashOf(mysqlSpec(auth: MySqlAuth.cachingSha2)),
      isNot(specHashOf(mysqlSpec(auth: MySqlAuth.nativePassword))),
    );
  });

  test('stops the server generating a certificate when TLS is off', () {
    expect(
      mysqlSpec(tls: const MySqlTls.off()).command,
      contains('--auto-generate-certs=OFF'),
    );
  });

  test('leaves TLS alone by default', () {
    // Paired with a flag source that is not empty, so the filter has
    // something to filter — otherwise an empty command list satisfies this
    // whatever the TLS default emits.
    expect(
      mysqlSpec(verboseLogs: true).command.where((a) => a.contains('certs')),
      isEmpty,
    );
  });

  test('turns on the general log only when asked', () {
    expect(mysqlSpec().command, isEmpty);
    expect(
      mysqlSpec(verboseLogs: true).command,
      containsAllInOrder(['mysqld', '--general-log=ON']),
    );
  });

  test('passes the lifetime and the labels through', () {
    final spec = mysqlSpec(
      lifetime: Lifetime.dedicated,
      labels: const {'suite': 'mine'},
    );

    expect(spec.lifetime, Lifetime.dedicated);
    expect(spec.labels['suite'], 'mine');
  });
}
