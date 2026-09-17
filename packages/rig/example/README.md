# example

`redis_example_test.dart` is the whole idea in thirty lines: declare a
container, get a host and a port that are ready to use.

Run it from this package's directory:

```bash
dart test example
```

It needs a running Docker daemon. The first run pulls `redis:7-alpine`; later
runs reuse the container rig left behind, so they start in about a second.

Two things in it are worth copying into your own tests:

- **The declaration goes at the top of `main()`**, not inside `setUpAll`. rig
  installs its own `setUpAll`, so the container is up before your first test
  and suites that declare the same spec share one container.
- **Never assume the port.** `redis.port(6379)` returns the host port Docker
  assigned, which is not 6379. That is what keeps the container from colliding
  with a Redis you already run locally.

`rig_postgres` has its own example showing the module API, where the
container's configuration — the authentication method, a database per suite —
is the part that matters.
