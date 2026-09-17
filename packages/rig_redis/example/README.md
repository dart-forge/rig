# Example

The runnable example lives at [examples/basic-sample](../../../examples/basic-sample)
in this repository, as a test file. This package is a library your *tests*
use, so an example that is not a test would misrepresent it — and keeping it
there means continuous integration runs it on every push.

```dart
import 'package:rig_redis/rig_redis.dart';
import 'package:test/test.dart';

void main() {
  // `password:` is the reason this module exists over `useContainer` with a
  // bare ContainerSpec: it does not just set a flag, it actually starts the
  // server with `--requirepass`, and rig's own integration suite proves a
  // wrong password is refused, not silently accepted.
  final redis = useRedis(password: 'hunter2');

  test('the suite gets a url carrying the password', () async {
    expect(redis.url, startsWith('redis://:hunter2@'));

    // Only the port is checked here, because this package depends on no
    // Redis client by design: implementing the auth handshake on the client
    // side is exactly what tests using this package are usually there to
    // verify. Hand `redis.url` to your own driver.
    expect(redis.host, isNotEmpty);
    expect(redis.port, greaterThan(0));
  });
}
```
