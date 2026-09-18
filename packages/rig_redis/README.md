# rig_redis

A Redis container for your Dart tests.

```dart
import 'package:rig_redis/rig_redis.dart';
import 'package:test/test.dart';

void main() {
  final redis = useRedis(password: 'hunter2');

  test('connects', () async {
    // redis://:hunter2@127.0.0.1:<port>/<index>. Hand it to whatever client
    // you are testing; this package deliberately depends on no Redis client.
    expect(redis.url, startsWith('redis://'));
  });
}
```

Suites that ask for the same configuration share one container.

## Isolation

By default (`RedisIsolation.database`), each suite is handed a database
index of its own inside the container, so suites sharing one container do
not see each other's keys. Ask for `RedisIsolation.none` to connect to index
0 instead — the container's own database, and the one a bare
`redis://host:port/` URL means — which suites sharing the container also
asking for `none` will see each other's keys in, on purpose.

Index 0 is reserved for `RedisIsolation.none` and is never handed to a
`database`-isolated suite, so allocation starts at 1: `databases:` sets the
size of the pool, and the number of indices actually available to suites is
one less than that.

An index whose suite crashed before teardown is reclaimed by a later suite
that needs one, and flushed before being handed out — a suite never sees a
predecessor's leftover keys, whether its index was freshly free or reused
from one a crashed suite never returned.

Asking for more indices than a container has left throws, naming how many
are in use and two ways out: raise `databases:`, or ask for
`lifetime: Lifetime.dedicated` for a container nothing else is drawing from.
A shared container's pool is not "per project" — it is shared by whatever
else on the machine lands on the same configuration too.

## Password

Passing `password:` starts the container with `--requirepass`, and it is
genuinely enforced — a connection with the wrong password is refused, not
silently accepted. Leave it null for no password.

## Databases

`databases:` sets how many databases (`SELECT 0` .. `SELECT n-1`) the
container's own `redis-server` is started with — it defaults to 64, not the
official image's own default of 16. A shared container is reused by any
suite whose configuration hashes the same, and that sharing crosses project
boundaries too: 64 is not "64 per project", it is 64 total, shared by this
repository's own tests and by every other project that lands on the same
container.

## What this does to a container you share

A shared container (the default) is reused by any suite whose configuration
hashes the same, and is **never removed** by a test run — the next run
reuses it instead of paying for startup again. Nothing in this package stops
or removes it; only `rig prune` does. Ask for `lifetime: Lifetime.dedicated`
when a suite would disturb others sharing the container.

## Installing

```bash
dart pub add dev:rig_redis
```

It brings [rig](https://pub.dev/packages/rig) with it. Containers are left
running on purpose, so you will also want
[rig_cli](https://pub.dev/packages/rig_cli) for the `rig` command that removes
them.

## Testing

```bash
dart test --exclude-tags integration   # no Docker needed
dart test --tags integration           # needs a running Docker daemon
```
