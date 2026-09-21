@Tags(['integration'])
library;

import 'package:rig/module.dart';
import 'package:rig/rig.dart';
import 'package:rig_mysql/rig_mysql.dart';
import 'package:test/test.dart';

void main() {
  // Dedicated, not shared: this test's whole point is the server's auth
  // cache state, and useMySql() re-runs confirmAuthMode's ALTER USER — which
  // re-hashes the password and so invalidates whatever caching_sha2_password
  // had cached for this user — in the setUpAll of every suite that shares a
  // container. mysql_tls_test.dart's "TLS off" group asks for this exact
  // same configuration, and running both concurrently reproduced the
  // interference every time: this test's own "warm the cache" step lost the
  // race against the other suite's confirmAuthMode landing in between it and
  // the final check. A dedicated container removes the other tenant.
  final my = useMySql(
    tls: const MySqlTls.off(),
    isolation: MySqlIsolation.none,
    lifetime: Lifetime.dedicated,
  );

  test('a cold cache forces the full authentication path', () async {
    // The point of flushAuthCache. With caching_sha2_password over a
    // connection that is not TLS, a client the cache does not know has to
    // fetch the server public key; one the cache knows does not. So the
    // official client fails without --get-server-public-key right after a
    // flush, and succeeds once the cache is warm. That difference is the
    // only observable proof that the cache was emptied.
    final engine = await currentEngine();

    Future<int> connect({required bool withTheKey}) async {
      final result = await engine.exec(my.container.containerId, [
        'mysql',
        '-h',
        '127.0.0.1',
        '-u${my.user}',
        '-p${my.password}',
        '--ssl-mode=DISABLED',
        if (withTheKey) '--get-server-public-key',
        '-N',
        '-B',
        '-e',
        'SELECT 1',
      ]);
      return result.exitCode;
    }

    // Warm the cache the way a client that has the key would. Until this
    // succeeds there is nothing for a flush to empty: the server populates
    // the cache only on a successful full authentication, and useMySql's own
    // setUpAll has already invalidated it by re-storing the password.
    expect(await connect(withTheKey: true), 0);

    // With the cache warm the fast path works without the key. This is the
    // assertion that makes the one after the flush mean anything — the only
    // difference between the two is the flush itself.
    expect(
      await connect(withTheKey: false),
      0,
      reason: 'a warm cache should take the fast path',
    );

    await my.flushAuthCache();

    expect(
      await connect(withTheKey: false),
      isNot(0),
      reason:
          'the flush should have emptied the cache, so a client without '
          'the public key has no way to authenticate',
    );
  });
}
