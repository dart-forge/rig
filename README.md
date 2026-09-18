# rig

Your tests start the containers they need.

A Dart test declares the Docker container it depends on. rig starts it if
nobody has, waits until it is actually usable, and hands back the port Docker
picked. No fixed ports to reserve, no `docker compose up` to remember first.

```dart
import 'dart:io';

import 'package:rig/rig.dart';
import 'package:test/test.dart';

void main() {
  final cache = useContainer(
    const ContainerSpec(
      image: 'redis:7-alpine',
      exposedPorts: [6379],
      waitFor: WaitFor.port(6379),
    ),
  );

  test('talks to redis', () async {
    final socket = await Socket.connect(cache.host, cache.port(6379));
    addTearDown(socket.close);
    // ...
  });
}
```

`dart test` gives every test file its own isolate, so there is no process-wide
place to keep a container. rig coordinates through Docker itself instead:
suites asking for the same configuration **share one container**, and each
module decides how suites stay out of each other's way inside it. That is the
design decision the rest follows from — see
[packages/rig/README.md](packages/rig/README.md) for what it implies about
cleanup and lifetimes.

## Layout

| | | |
| --- | --- | --- |
| [packages/rig](packages/rig) | [![Pub Version](https://img.shields.io/pub/v/rig)](https://pub.dev/packages/rig) | The library. `useContainer`, the wait strategies, the lease. |
| [packages/rig_postgres](packages/rig_postgres) | [![Pub Version](https://img.shields.io/pub/v/rig_postgres)](https://pub.dev/packages/rig_postgres) | Postgres with the authentication method genuinely in force, and a database per suite. |
| [packages/rig_redis](packages/rig_redis) | [![Pub Version](https://img.shields.io/pub/v/rig_redis)](https://pub.dev/packages/rig_redis) | Redis with a password that is genuinely enforced, and a database index per suite. |
| [packages/rig_cli](packages/rig_cli) | [![Pub Version](https://img.shields.io/pub/v/rig_cli)](https://pub.dev/packages/rig_cli) | The `rig` command — `ls` and `prune`, because containers are left running on purpose. |
| [examples/basic-sample](examples/basic-sample) | — | Runnable examples, paired with real drivers and run by CI. Not published. |

## Running the tests

This is a pub workspace, and **`dart test` at the root runs nothing** — it
matches no tests and exits zero, which looks like success. Run it per package:

```bash
cd packages/rig && dart test                          # 270 tests
cd packages/rig && dart test --exclude-tags integration   # 256, no Docker needed
cd packages/rig && dart test --tags integration           # 14, needs a daemon
```

The same applies to `packages/rig_cli`, `packages/rig_postgres`,
`packages/rig_redis` and `examples/basic-sample`. Integration suites here are
**not** skipped by default; they carry a timeout multiplier instead, so a
plain `dart test` runs everything the package has and needs Docker.

Continuous integration runs analyze, format, and every package on
`ubuntu-latest`. GitHub's macOS runners ship no Docker, so macOS socket
discovery is not covered there — that gap is noted in the workflow rather than
hidden behind a skipped job. A CI runner is always cold, which means the image
pull, `initdb`, and several suites racing to create the same container get
exercised on every push, paths a developer's machine skips by reusing what is
already running.

## Status

Published on pub.dev: [rig](https://pub.dev/packages/rig),
[rig_postgres](https://pub.dev/packages/rig_postgres),
[rig_redis](https://pub.dev/packages/rig_redis),
[rig_cli](https://pub.dev/packages/rig_cli). The four are released together.
