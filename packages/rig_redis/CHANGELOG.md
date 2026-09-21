## 0.4.0

- No change in behaviour. The suite marker rule moved into `rig`; this package
  now uses it.

## 0.3.0

No functional change in this package. It moves to `rig: ^0.3.0`, because
`^0.2.0` does not admit rig 0.3.0 and would otherwise hold you to rig 0.2.x.

## 0.2.0

No functional change in this package. It moves to `rig: ^0.2.0`, because
`^0.1.0` does not admit rig 0.2.0 and would otherwise hold you to rig 0.1.x.

One consequence is worth knowing: rig 0.2.0 changes every configuration hash,
so the containers 0.1.0 left running are not reused. The first run on this
version creates fresh ones and leaves the old ones behind; `rig prune` clears
them.

## 0.1.0

First release.

- `useRedis()` gives a test suite a Redis container and a connection string
  for it.
- **The official image ships no healthcheck**, so this module injects one.
  `redis-cli ping` can exit `0` even when it failed (e.g. against a
  password-protected server it was not authenticated for), so the injected
  check greps the output for `PONG` instead of trusting the exit code.
- **A password is genuinely enforced.** Passing `password:` starts the
  container with `--requirepass`; a connection with the wrong password is
  refused, not silently accepted.
- `databases:` sets the container's own database count and defaults to 64,
  not the official image's default of 16 — a shared container's databases
  are shared across every suite and every project that lands on it, not per
  project.
- **A database index per suite.** Suites sharing a container each get their
  own index (`RedisIsolation.database`, the default), claimed from the pool
  `databases:` sizes and released when the suite ends; index 0 is reserved
  for `RedisIsolation.none`, which connects suites to the container's own
  database on purpose. An index left behind by a suite that crashed before
  teardown is reclaimed by a later suite and flushed before being handed
  out, so it never carries a crashed suite's keys.
- Speaks to the server through `redis-cli` inside the container, so this
  package adds no Redis client dependency.
