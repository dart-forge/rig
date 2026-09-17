# example

`postgres_example_test.dart` shows the two things this module adds on top of
`rig`: a Postgres whose **authentication method is really in force**, and a
**database per suite**.

Run it from this package's directory:

```bash
dart test example
```

It needs a running Docker daemon. The first run pulls `postgres:16-alpine` and
runs initdb; later runs reuse the container, so they take about a second.

Why `auth:` is the whole point: setting the method without re-hashing the
password leaves Postgres using SCRAM no matter what `pg_hba.conf` says, so a
test that believes it exercises md5 exercises nothing. `usePostgres` re-hashes
the password after the server is up and confirms the stored verifier has the
shape the method requires.

Why the database name is not `test_db`: `dart test` gives every test file its
own isolate, and suites asking for the same configuration share one container.
Each suite therefore creates a database of its own inside it, and drops it in
teardown. Connect with `pg.url` (or `pg.database`) rather than a fixed name —
the name carries the project and the run, so it changes.

The example only opens a socket, because rig depends on no Postgres client by
design: md5, SCRAM and TLS on the client side are what these suites exist to
test, so depending on a client would mean testing this package against itself.
Hand `pg.url` to your own driver.
