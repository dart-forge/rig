@Tags(['integration'])
library;

import 'package:rig/module.dart';
import 'package:rig_mysql/rig_mysql.dart';
import 'package:test/test.dart';

void main() {
  final my = useMySql(
    tls: const MySqlTls.off(),
    isolation: MySqlIsolation.none,
  );

  test('a cold cache forces the full authentication path', () async {
    // The point of flushAuthCache. With caching_sha2_password over a
    // connection that is not TLS, a client the cache does not know has to
    // fetch the server public key; one the cache knows does not. So the
    // official client fails without --get-server-public-key right after a
    // flush, and succeeds once the cache is warm. That difference is the
    // only observable proof that the cache was emptied.
    final engine = await currentEngine();

    Future<int> connectWithoutTheKey() async {
      final result = await engine.exec(my.container.containerId, [
        'mysql',
        '-h',
        '127.0.0.1',
        '-u${my.user}',
        '-p${my.password}',
        '--ssl-mode=DISABLED',
        '-N',
        '-B',
        '-e',
        'SELECT 1',
      ]);
      return result.exitCode;
    }

    await my.flushAuthCache();
    expect(
      await connectWithoutTheKey(),
      isNot(0),
      reason: 'a cold cache should have demanded the public key',
    );

    // Warm the cache the way a client that has the key would.
    final warmed = await engine.exec(my.container.containerId, [
      'mysql',
      '-h',
      '127.0.0.1',
      '-u${my.user}',
      '-p${my.password}',
      '--ssl-mode=DISABLED',
      '--get-server-public-key',
      '-N',
      '-B',
      '-e',
      'SELECT 1',
    ]);
    expect(warmed.exitCode, 0, reason: warmed.output);

    expect(
      await connectWithoutTheKey(),
      0,
      reason: 'a warm cache should take the fast path',
    );
  });
}
