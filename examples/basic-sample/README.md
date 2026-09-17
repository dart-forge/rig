# basic-sample

The smallest thing that shows what rig does. Two test files, no application
code: rig is a library your *tests* use, so an example that is not a test would
misrepresent it.

```bash
cd examples/basic-sample
dart test
```

It needs a running Docker daemon. The first run pulls the images; later runs
reuse the containers rig deliberately leaves behind, so they take about a
second. CI runs these files on every push, which is what keeps them honest as
the API moves.

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

Both examples only open a socket rather than speaking the protocol, because rig
depends on no database client by design: implementing md5, SCRAM and TLS on the
client side is exactly what its own tests exist to verify, so a client
dependency would mean testing rig against itself. Hand `pg.url` to your driver.

## `test/redis_password_test.dart` — what the Redis module adds

`useRedis` gives you a Redis whose **password is genuinely enforced**: pass
`password:` and the container is started with `--requirepass`, and rig's own
integration suite proves a wrong password is refused rather than silently
accepted. Connect with `redis.url`, which carries the password already
percent-encoded.
