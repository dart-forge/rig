# rig

Your tests start the containers they need.

A test declares the container it depends on. rig starts it if nobody has,
waits until it is actually usable, and hands back the port Docker picked. No
fixed ports to reserve, no `docker compose up` to remember, no container
stopped out from under a suite that is still using it.

```dart
import 'dart:io';

import 'package:rig/rig.dart';
import 'package:test/test.dart';

void main() {
  // At the top of main(), not inside setUpAll: rig installs its own setUpAll,
  // so the container is ready before your first test runs.
  final cache = useContainer(
    const ContainerSpec(
      image: 'redis:7-alpine',
      exposedPorts: [6379],
      waitFor: WaitFor.port(6379),
    ),
  );

  test('talks to redis', () async {
    // Never 6379 on the host — Docker picked the port, and that is what keeps
    // this from colliding with a Redis you already run locally.
    final socket = await Socket.connect(cache.host, cache.port(6379));
    addTearDown(socket.close);
    // ...
  });
}
```

## Waiting until it is usable

Starting a container is not the hard part; knowing when it is ready is. A
strategy is pure data — it says what to check, never how — so a spec stays
const-constructible and rig can hash it.

| Strategy | Waits for |
| --- | --- |
| `WaitFor.healthy()` | Docker's own health status. Needs a healthcheck; most official images ship none, so `ContainerSpec.healthcheck` can inject one. |
| `WaitFor.port(6379)` | The mapped host port to accept a connection. |
| `WaitFor.httpOk(8080, path: '/health')` | A GET to answer the status you name. |
| `WaitFor.logMessage('ready')` | A `String` or `RegExp` to appear in the log. The only option for a container that neither opens a port nor has a healthcheck. |
| `WaitFor.all([...])` | All of them, concurrently. |

## Suites share containers

This is the part that differs most from other testcontainers implementations,
and it is not a tuning knob — it follows from how Dart tests run.

`dart test` gives **every test file its own isolate**, with no shared memory.
There is no process-wide singleton to park a container in. So rig coordinates
outside the process instead: a container is labelled with a hash of the spec
that asked for it, and suites wanting that same spec find it and share it. The
first one there creates it, under a lock; the others wait and join.

What follows from that:

- **Containers outlive the test run.** rig does not stop them, because
  stopping one would pull it out from under another suite — and because the
  next run then starts in about a second instead of paying startup again.
- **Cleaning up is a separate, explicit act.** `pruneContainers()` does it
  from code, so a project that only added a module such as `rig_postgres` —
  and never added `rig_cli` — still has a way to clean up. It defaults to
  the same safe cutoffs a bare `rig prune` uses (seven days for shared
  containers, one hour for dedicated ones); `all: true` drops both and
  removes every container rig ever made, which is only safe to call where
  nothing else could be relying on one — see its doc comment before reaching
  for it from a test suite. The `rig_cli` package wraps it in a `rig`
  command for the terminal: `rig ls` shows what is running, `rig prune`
  removes shared containers older than seven days, `rig prune --all` removes
  every container rig created without looking at whether something is using
  it.
- **`Lifetime.dedicated`** opts a suite out of sharing when a test genuinely
  needs a server to itself. Those are removed when the suite ends.
- **Isolation inside a shared container is the module's job.** `rig_postgres`,
  for example, gives each suite a database of its own rather than letting
  suites share one.

## Reaching into the container

```dart
final result = await cache.exec(['redis-cli', 'INFO', 'server']);
print(result.output);

print(await cache.logTail(lines: 20));
```

`exec` throws `ExecFailed` when the command exits non-zero. That is the
opposite of what most testcontainers ports do, and it is deliberate: silently
ignoring an exit code is a mistake this library has already made once, in a
cleanup path that reported work it had not done. Pass `expectSuccess: false`
where a failure is a legitimate outcome.

## Files needed before the container starts

`ContainerLease.putFile` and a bind mount both write into the container, but
neither works for a server that reads its configuration **at startup**:
`putFile` runs after the container is already up, and a mount brings the
*host's* ownership with it, which can leave a file unreadable to whatever
non-root process was meant to read it. `ContainerSpec.files` places files
before `start`, with the mode and ownership you ask for:

```dart
final spec = ContainerSpec(
  image: 'my-app:test',
  files: [
    ContainerFile(
      '/etc/my-app/config.yaml',
      utf8.encode('log_level: debug'),
      mode: '640',
      uid: 1000,
      gid: 1000,
    ),
  ],
  waitFor: WaitFor.port(8080),
);
```

`uid`/`gid` must be **numbers**, not names: Docker ignores a tar entry's
user/group name and only ever applies the numeric id, so rig has no way to
resolve `'app-user'` to whatever id it is inside your image — you have to
know it.

Only the file itself is written; rig never sends a directory entry for any
of its parents. Doing so would overwrite an existing directory's own mode and
owner with whatever this write happened to carry — a real, measured failure:
a tar carrying `etc/` at mode 700 turned a container's `/etc` into
`drwx------`, unreadable to anything not running as root. Docker creates
missing parent directories itself, as `755` owned by root, so a deep path
like the one above works without rig ever touching `/etc`.

Because a shared container's identity already includes these files' content,
mode, and ownership (the same way a mount's content does), a suite that finds
an existing container reuses it as-is — rig does not rewrite its files on
every acquire, which could stomp on a file another suite is using right now.

## Building an image

```dart
final spec = ContainerSpec(
  image: 'my-app:test', // the tag rig builds and then runs
  build: ContainerBuild(context: 'test/fixtures/my-app'),
  waitFor: WaitFor.port(8080),
);
```

If the build context has a `.dockerignore`, rig interprets it before sending
anything — the Docker daemon's own `/build` endpoint does not, so a file the
`.dockerignore` excludes never leaves your machine. Supported: `#` comments,
blank lines, `!` negation, `*`, `?`, and `**`. The last pattern that matches a
given path decides its fate, so a later line can undo an earlier one and vice
versa.

**`*` does not cross `/`.** `*.log` excludes `error.log` but leaves
`sub/error.log` alone — matching `docker build`'s own behavior, not the
recursive glob many people expect. Write `**/*.log` to reach every directory.

A pattern rig cannot interpret — currently just a character class like
`[a-z]` — throws rather than silently sending the file anyway: getting this
wrong ships something you meant to exclude, which is worse than refusing to
build.

`ContainerBuild.dockerfile` is always sent even if `.dockerignore` excludes
it, the same way `docker build` itself keeps working when the Dockerfile is
excluded.

Two things to know if you compare results with `docker build`:

- **rig is more permissive about re-including a file inside an excluded
  directory.** Given `sub` followed by `!sub/keep.txt`, `docker build` still
  drops `keep.txt` — it stops walking `sub` and never considers what is
  inside — while rig applies last-match-wins and sends it. rig errs toward
  the file you explicitly asked to keep; the direction that would matter,
  sending something you excluded, cannot happen.
- **`.dockerignore` applies to builds only.** `ContainerLease.copyInto`
  ignores one sitting in the directory you are copying, because that file
  describes a build context and quietly dropping files from a copy would be
  a surprise for an unrelated reason.

## Requirements

- Dart SDK 3.13 or newer.
- A reachable Docker daemon. rig talks to the Engine API over its Unix socket
  directly — no Docker CLI, and no dependency beyond `crypto`, `meta`, `path`
  and `test`.
- Linux and macOS. The continuous integration for this repository runs on
  Linux only, because GitHub's macOS runners have no Docker, so macOS socket
  discovery is exercised by hand rather than by CI.

## Modules

A module packages the knowledge of one service: how to configure it, how to
tell when it is ready, and how to keep suites from treading on each other.

- [`rig_postgres`](../rig_postgres) — Postgres with the authentication method
  genuinely in force, and a database per suite.

## Installing

rig is only ever a test dependency — nothing in your shipped code imports it.

```bash
dart pub add dev:rig
```

For Postgres reach for [rig_postgres](https://pub.dev/packages/rig_postgres)
rather than building the spec yourself, and add
[rig_cli](https://pub.dev/packages/rig_cli) to get the `rig` command that
lists and removes the containers left behind.
