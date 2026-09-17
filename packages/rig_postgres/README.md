# rig_postgres

A Postgres container for your Dart tests, in the authentication mode you are
actually testing.

```dart
import 'package:rig_postgres/rig_postgres.dart';
import 'package:test/test.dart';

void main() {
  final pg = usePostgres(auth: PgAuth.scram);

  test('connects', () async {
    // pg.url is postgresql://test:test@127.0.0.1:<port>/<your own database>
  });
}
```

Suites that ask for the same configuration share one container and each get
their own database inside it, so they do not see each other's tables.

## Auth modes

`PgAuth` picks how the server authenticates a TCP connection:

- `password` — the client sends the password in the clear. Useful when the
  point is not the handshake.
- `md5` — MD5 challenge-response.
- `scram` — SCRAM-SHA-256, the modern default.

## What this does to a container you share

A shared container (the default) is reused by any suite whose configuration
hashes the same, and is **never removed** by a test run — the next run
reuses it instead of paying for startup again. Nothing in this package
stops or removes it; only `rig prune` does. Ask for `lifetime:
Lifetime.dedicated` when a suite would disturb others sharing the
container — connection limits, killing backends, restarts.

Inside a shared container, each suite gets a database of its own named
`test_<project>_<minute>_<token>`. A sweep runs before each suite creates
its database and **drops other suites' `test_*` databases** that are old
enough (an hour, by default) and that nothing still claims — this is what
keeps a long-lived shared container from accumulating databases from
crashed runs forever. It never touches the container's own database, and
never touches a database some other suite still has open.

## Testing

```bash
dart test --exclude-tags integration   # no Docker needed
dart test --tags integration           # needs a running Docker daemon
```
