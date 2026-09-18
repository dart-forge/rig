# basic-sample

The smallest thing that shows what rig does. No application code: rig is a
library your *tests* use, so an example that is not a test would misrepresent
it.

```bash
cd examples/basic-sample
dart test
```

It needs a running Docker daemon. The first run pulls the images; later runs
reuse the containers rig deliberately leaves behind, so they take about a
second. CI runs these files on every push, which is what keeps them honest as
the API moves.

This package's `pubspec.yaml` depends on `postgres` and `aim_postgres` — real
database clients. That is not a contradiction of rig's own dependency-free
design: `rig` and `rig_postgres` still depend on nothing but Docker, this
example package is `publish_to: none`, and the whole point of the two driver
files below is to show rig next to the client you would actually use.

## `test/redis_test.dart` — the core idea

Declare a container at the top of `main()` and you get a host and a port that
are ready to use. Two things worth copying:

- **The declaration goes at the top of `main()`**, not inside `setUpAll`. rig
  installs its own `setUpAll`, so the container is up before your first test,
  and suites declaring the same spec share one container.
- **Never assume the port.** `redis.port(6379)` returns the host port Docker
  assigned, which is not 6379. That is what keeps it from colliding with a
  Redis you already run locally.

## `test/postgres_test.dart` — what a module adds

`usePostgres` gives you a Postgres whose **authentication method is really in
force**, and a **database of the suite's own**.

The authentication part is the reason the module exists: set the method without
re-hashing the password and Postgres quietly keeps using SCRAM, so a test that
believes it exercises md5 exercises nothing. `usePostgres` re-hashes after the
server is up and confirms the stored verifier has the shape the method requires.

The database part follows from how `dart test` works: every test file gets its
own isolate, and suites wanting the same configuration share one container — so
each suite creates a database of its own inside it and drops it in teardown.
Connect with `pg.url` rather than a fixed name; the name carries the project and
the run, so it changes.

This file only opens a socket rather than speaking the protocol, because rig
itself depends on no database client by design: implementing md5, SCRAM and TLS
on the client side is exactly what its own tests exist to verify, so a client
dependency would mean testing rig against itself. The next two files are where
a real client shows up.

## `test/postgres_driver_test.dart` — how to point a real driver at the container

`usePostgres()` plus `package:postgres`, doing real work: create a table,
insert a row, read it back. Every field on the `Endpoint` — `host`, `port`,
`database`, `username`, `password` — comes from the `PostgresLease`, so
nothing here is a literal that merely happens to match `usePostgres()`'s
defaults.

The line worth reading twice is `ConnectionSettings(sslMode: SslMode.disable)`.
package:postgres v3 asks for TLS by default; `usePostgres()` starts a server
with no TLS configured at all. Skip that line and the connection fails with
`Server does not support SSL, but it was required (default configuration).` —
which is the first thing most readers hit, so the file says why right next to
it.

## `test/aim_postgres_driver_test.dart` — that two suites share one container

The same `usePostgres()` call as the file above, driven by `aim_postgres`
instead — a second driver from this ecosystem, but not rig's own. Its
`PostgresDatabase.connect` takes `pg.url` directly, and needs no `sslMode` line:
`aim_postgres` defaults an unspecified `sslmode` to `disable`, so there is
nothing to opt out of.

The two files declare an identical spec on purpose. That is what lets this
example show rig's central behaviour: **rig hands both suites the same
container**, while `PgIsolation.database` still gives each one a database of
its own inside it. Neither file imports or refers to the other — running just
one of them behaves no differently. Checked by printing
`pg.container.containerId` from both suites in one `dart test` run: identical
container id, two distinct `pg.database` values.

## `test/redis_password_test.dart` — what the Redis module adds

`useRedis` gives you a Redis whose **password is genuinely enforced**: pass
`password:` and the container is started with `--requirepass`, and rig's own
integration suite proves a wrong password is refused rather than silently
accepted. Connect with `redis.url`, which carries the password already
percent-encoded.

## `test/startup_test.dart` — features with no example anywhere else

A tour, not a test suite, of three things rig can do that the files above
never needed: `files:` places a file inside the container before its command
ever runs (a bind mount would work too, but arrives owned by the host's user,
which is often not who the container runs as); `WaitFor.logMessage` waits on
something printed to the log instead of a port or a healthcheck, for a
container with neither; and `ContainerLease.exec` runs a command inside the
container after it is up, to look at what is there.
