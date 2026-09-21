@Tags(['integration'])
library;

import 'package:rig/module.dart';
import 'package:rig_mysql/rig_mysql.dart';
import 'package:test/test.dart';

Future<int> connectRequiringTls(MySqlLease my) async {
  final engine = await currentEngine();
  // Over TCP, not the socket: a unix socket connection is treated as already
  // secure and would not exercise TLS either way.
  final result = await engine.exec(my.container.containerId, [
    'mysql',
    '-h',
    '127.0.0.1',
    '-uroot',
    '-p${my.rootPassword}',
    '--ssl-mode=REQUIRED',
    '-N',
    '-B',
    '-e',
    'SELECT 1',
  ]);
  return result.exitCode;
}

void main() {
  group('the server default', () {
    final my = useMySql(isolation: MySqlIsolation.none);

    test('accepts a connection that requires TLS', () async {
      // MySQL generates a self-signed certificate at initialisation, so this
      // works without rig supplying anything.
      expect(await connectRequiringTls(my), 0);
    });
  });

  group('TLS off', () {
    final my = useMySql(
      tls: const MySqlTls.off(),
      isolation: MySqlIsolation.none,
    );

    test('refuses a connection that requires TLS', () async {
      // Checked by behaviour rather than by reading a server variable: the
      // names move between versions (have_ssl was removed in 8.0.26), so a
      // variable-based check passes on one version and lies on another.
      expect(await connectRequiringTls(my), isNot(0));
    });

    test('still accepts a connection that does not require it', () async {
      // Otherwise this would be indistinguishable from a broken container.
      final engine = await currentEngine();
      final result = await engine.exec(my.container.containerId, [
        'mysql',
        '-h',
        '127.0.0.1',
        '-uroot',
        '-p${my.rootPassword}',
        '--ssl-mode=DISABLED',
        '--get-server-public-key',
        '-N',
        '-B',
        '-e',
        'SELECT 1',
      ]);

      expect(result.exitCode, 0, reason: result.output);
    });
  });
}
