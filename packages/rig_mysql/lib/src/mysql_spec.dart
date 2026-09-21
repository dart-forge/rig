import 'package:rig/rig.dart';

import 'mysql_auth.dart';
import 'mysql_tls.dart';

/// The container a MySQL of this shape needs.
ContainerSpec mysqlSpec({
  String version = '8.4',
  MySqlAuth auth = MySqlAuth.cachingSha2,
  bool verboseLogs = false,
  int? maxConnections,
  String user = 'test',
  String password = 'test',
  String rootPassword = 'root',
  String database = 'test_db',
  Lifetime lifetime = Lifetime.shared,
  MySqlTls tls = const MySqlTls.serverDefault(),
  Map<String, String> labels = const {},
}) {
  final flags = [
    ...setupFor(auth).serverFlags,
    ...tlsServerFlags(tls),
    if (maxConnections != null) '--max-connections=$maxConnections',
    if (verboseLogs) ..._verboseFlags,
  ];

  // Nothing here outlives the container, and initialising a fresh data
  // directory is most of the startup.
  const dataDir = '/var/lib/mysql';

  return ContainerSpec(
    image: 'mysql:$version',
    env: {
      'MYSQL_ROOT_PASSWORD': rootPassword,
      'MYSQL_USER': user,
      'MYSQL_PASSWORD': password,
      'MYSQL_DATABASE': database,
    },
    // `mysqld` has to lead: the official entrypoint treats a command
    // starting with a flag as arguments to its own default. Naming the
    // binary is what the image's documentation does and does not lean on
    // that. With no flags, saying nothing at all lets the image's default
    // run, which is the smaller claim.
    command: flags.isEmpty ? const [] : ['mysqld', ...flags],
    exposedPorts: const [3306],
    tmpfs: const {dataDir},
    labels: labels,
    healthcheck: const Healthcheck(
      // -h 127.0.0.1 is the load-bearing part. During initialisation the
      // entrypoint runs a temporary server with --skip-networking, so a
      // probe that does not name TCP can succeed against that one and
      // report ready while initialisation is still going.
      //
      // No credentials: mysqladmin ping exits 0 even when the login is
      // refused, because the server answered — which is all this needs to
      // know. Passing the password would put it in the container's own
      // process list for nothing.
      test: ['CMD-SHELL', 'mysqladmin ping -h 127.0.0.1 --silent'],
      interval: Duration(milliseconds: 250),
      timeout: Duration(seconds: 3),
      retries: 60,
    ),
    // The port answers well before the server will authenticate anyone, and
    // a cold image pull plus initialisation is slow.
    waitFor: const WaitFor.healthy(timeout: Duration(seconds: 120)),
    lifetime: lifetime,
  );
}

const List<String> _verboseFlags = [
  '--general-log=ON',
  '--general-log-file=/dev/stdout',
  '--log-error-verbosity=3',
];
