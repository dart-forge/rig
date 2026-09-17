## 0.1.0

First release.

- `usePostgres()` gives a test suite a Postgres container and a connection
  string for it.
- **The authentication method is genuinely in force.** Naming `PgAuth.md5` or
  `PgAuth.scram` is not enough on its own: Postgres stores a verifier when the
  password is set, so changing the method afterwards leaves the old verifier
  in place and a test that believes it exercises md5 exercises nothing.
  `usePostgres` re-hashes the password once the server is up and then confirms
  the stored verifier has the shape the method requires.
- **A database per suite.** Suites sharing a container each get their own
  database, created before the suite runs and dropped when it ends, so
  concurrent suites never see each other's tables.
- Databases left behind by a run that died before teardown are reclaimed on a
  later run, guarded by a marker file so a suite between connections is not
  mistaken for an abandoned one.
- `PgTls.selfSigned` generates a certificate with the host's `openssl` and
  arranges for Postgres to read it, working around bind mounts appearing as
  `root:root` inside the container.
- `verboseLogs: true` turns on statement, connection and duration logging.
- Speaks to the server through `psql` inside the container, so this package
  adds no Postgres client dependency — the client side of md5, SCRAM and TLS
  is exactly what tests using this package are usually there to verify.
