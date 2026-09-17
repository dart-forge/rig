# rig_redis

A Redis container for your Dart tests.

```dart
import 'package:rig_redis/rig_redis.dart';
import 'package:test/test.dart';

void main() {
  final redis = useRedis(password: 'hunter2');

  test('connects', () async {
    // redis://:hunter2@127.0.0.1:<port>/0. Hand it to whatever client you
    // are testing; this package deliberately depends on no Redis client.
    expect(redis.url, startsWith('redis://'));
  });
}
```

Suites that ask for the same configuration share one container.

## Password

Passing `password:` starts the container with `--requirepass`, and it is
genuinely enforced — a connection with the wrong password is refused, not
silently accepted. Leave it null for no password.

## Databases

`databases:` sets how many databases (`SELECT 0` .. `SELECT n-1`) the
container's own `redis-server` is started with — it defaults to 64, not the
official image's own default of 16. A shared container is reused by any
suite whose configuration hashes the same, and that sharing crosses project
boundaries too: 16 is not "16 per project", it is 16 total, shared by this
repository's own tests and by every other project that lands on the same
container. There is no per-suite database of its own yet — every suite
sharing a container currently sees index 0.

## What this does to a container you share

A shared container (the default) is reused by any suite whose configuration
hashes the same, and is **never removed** by a test run — the next run
reuses it instead of paying for startup again. Nothing in this package stops
or removes it; only `rig prune` does. Ask for `lifetime: Lifetime.dedicated`
when a suite would disturb others sharing the container.

## Testing

```bash
dart test --exclude-tags integration   # no Docker needed
dart test --tags integration           # needs a running Docker daemon
```
