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
  project. Per-suite isolation across that pool is not part of this release.
- Speaks to the server through `redis-cli` inside the container, so this
  package adds no Redis client dependency.
