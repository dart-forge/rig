# rig_mysql

A MySQL container for your Dart tests, storing the password under the
authentication plugin you actually asked for.

```dart
import 'package:rig_mysql/rig_mysql.dart';
import 'package:test/test.dart';

void main() {
  final my = useMySql();

  test('connects', () async {
    // mysql://test:test@127.0.0.1:<port>/<this suite's own database>.
    // Hand it to whatever driver you are testing; this package deliberately
    // depends on no MySQL client.
    expect(my.url, startsWith('mysql://'));
    expect(my.database, isNot('test_db'));
  });
}
```

Suites that ask for the same configuration share one container and, by
default, each get their own database inside it — see Isolation below to
change that.

MySQL 8.0 and 8.4 are the only versions this package is tested against and
supports; the default is `'8.4'`.

## Auth modes

`MySqlAuth` picks the plugin the server stores — and authenticates — the
password under:

- `cachingSha2` (the default) — SHA-256 based, with a cache on the server.
  MySQL's own default since 8.0.
- `nativePassword` — the pre-8.0 default, still widely deployed, and not
  loaded by default in 8.4. Ask for it with
  `useMySql(auth: MySqlAuth.nativePassword)`.

Naming a mode is not enough on its own. The official image stores the
password during initialisation under whatever the server's default plugin
happened to be at that moment, and changing the default afterwards does not
re-hash what is already stored — so a container could quietly go on
authenticating with a plugin the test never asked for. `useMySql` re-stores
the password again once the server is up, under the plugin `auth:` actually
names, which is what turns the auth mode into something a test asserts
rather than hopes for.

## TLS

`MySqlTls` has two states:

- `MySqlTls.serverDefault()` (the default) — MySQL's own behaviour: a
  self-signed certificate generated at initialisation, and TLS accepted with
  it.
- `MySqlTls.off()` — no TLS at all.

`caching_sha2_password` sends the password in the clear over TLS, but needs
the server's public key to do the same without one — and the only way to
exercise that second path is a server that speaks no TLS to begin with.
MySQL enables TLS by default, so a container with none has to be asked for
explicitly with `MySqlTls.off()`.

## Isolation

`MySqlIsolation` picks how much of the container a suite gets:

- `database` (the default) — a database of this suite's own, inside a
  container other suites share.
- `none` — connect straight to the container's own database; suites sharing
  the container see each other's tables.

## Why there is a `rootPassword`

`MYSQL_USER` is not a superuser, unlike the user the Postgres image creates.
A test that needs to create a schema, grant a privilege, or read
`mysql.user` has to connect as root, and `rootPassword` (default `'root'`) is
what makes that connection possible.

## `flushAuthCache()`

`caching_sha2_password` has two paths: a client the server's cache already
knows proves itself with a fast SHA-256 scramble, and one it does not has to
fall back to sending the password in a form the server can recover — in the
clear over TLS, or encrypted with the server's public key without it. By the
second connection, the server's cache already knows the client, so testing
that fallback path at all means being able to empty the cache first.

`my.flushAuthCache()` does that. It lives on the lease rather than in the
test because the client under test is exactly the thing whose connection is
being asserted on — asking it to run `FLUSH PRIVILEGES` before proving it
can connect is circular.

## What this does to a container you share

A shared container (the default) is reused by any suite whose configuration
hashes the same, and is **never removed** by a test run — the next run
reuses it instead of paying for startup again. Nothing in this package stops
or removes it; only `rig prune` does.

Inside a shared container, each suite gets a database of its own named
`test_<project>_<minute>_<token>`. A sweep runs before each suite creates its
database and drops other suites' `test_*` databases that are old enough (an
hour, by default) and that no marker still claims — this is what keeps a
long-lived shared container from accumulating databases from crashed runs
forever. The container's own database is never one of them, since its name
never has the shape a suite's own database is given. Unlike the Postgres
sibling, MySQL's `DROP DATABASE` succeeds even while something is still
connected, so the marker is the only thing standing between a live suite and
the sweep, not a second line of defence.

Ask for `lifetime: Lifetime.dedicated` when a suite would disturb others
sharing the container — connection limits, restarts, or assertions that
depend on the authentication cache being warm. Every suite that joins a
shared container re-stores the password in its own `setUpAll` (see Auth
modes above), and that statement cools the cache for whoever else is
connected to it.

## Installing

```bash
dart pub add dev:rig_mysql
```

It brings [rig](https://pub.dev/packages/rig) with it. Containers are left
running on purpose, so you will also want
[rig_cli](https://pub.dev/packages/rig_cli) for the `rig` command that
removes them.

## Testing

`dart test` runs everything, integration suites included, so it needs a
running Docker daemon.

```bash
dart test                  # everything — needs Docker
dart test -t integration   # only the integration suites
```
