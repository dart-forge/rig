// A Redis started with a password that is genuinely enforced.
//
// Run it: `dart test` from examples/basic-sample. It is a test rather than a
// script because that is how the module is used — `useRedis` calls
// `setUpAll` — and because CI runs it, which keeps it honest as the API
// moves.
@Tags(['integration'])
library;

import 'package:rig_redis/rig_redis.dart';
import 'package:test/test.dart';

void main() {
  // `password:` is the reason this module exists over `useContainer` with a
  // bare ContainerSpec: it does not just set a flag, it actually starts the
  // server with `--requirepass` and rig's own integration suite proves a
  // wrong password is refused, not silently accepted.
  final redis = useRedis(password: 'hunter2');

  test('the suite gets a url carrying the password', () async {
    // A connection string any Redis client accepts as-is.
    expect(redis.url, startsWith('redis://:hunter2@'));

    // Only the port is checked here, because rig depends on no Redis client
    // by design: implementing the auth handshake on the client side is
    // exactly what tests using this package are usually there to verify.
    // Hand `redis.url` to your own driver.
    expect(redis.host, isNotEmpty);
    expect(redis.port, greaterThan(0));
  });
}
