## Unreleased

- `pruneContainers()` — the decision logic behind `rig prune` moved from
  `rig_cli` into `rig` itself, and is now exported from `rig.dart`. A
  project that added only a module such as `rig_postgres`, and never added
  `rig_cli`, previously had no way to clean up at all; now it can call
  `pruneContainers()` directly. It returns a `PruneResult` rather than
  printing — `rig_cli`'s `rig prune` command now just formats it. `all`
  defaults to `false` for the same reason it always has, stated more
  bluntly here than in the CLI's `--all` help: a container this removes is
  *certainly* in use by something, possibly a suite in a different project
  entirely, since containers are shared across project boundaries.

## 0.2.0

- **Containers from 0.1.0 are not reused.** Adding a field to `ContainerSpec`
  changes every configuration hash, so the first run on this version creates
  fresh containers and leaves the old ones behind. `rig prune` clears them.

- `ContainerSpec.files` places files inside the container **before it
  starts**, for a server that reads its configuration at startup — too late
  for `ContainerLease.putFile`, and unlike a bind mount, without the host's
  ownership coming along for the ride. Each `ContainerFile` carries its own
  `mode`, `uid`, and `gid`; `uid`/`gid` must be numeric ids, since Docker
  ignores a tar entry's user/group name. Only the file itself is ever
  written — never a directory entry for its parents, which would overwrite
  an existing directory's own mode and owner. Folded into the configuration
  hash by path, mode, uid, gid, and content, the same way a mount's content
  is; two files at the same path throw rather than silently picking a
  winner.

## 0.1.0

First release.

- `useContainer(spec)` declares the container a test suite needs. rig starts
  it if nobody has, waits until it is usable, and hands back the host port
  Docker assigned.
- Suites asking for the same configuration **share one container**, which is
  the default rather than an opt-in. `dart test` gives every test file its own
  isolate, so the coordination lives in Docker labels and a lock on disk
  rather than in a process-wide singleton.
- Wait strategies: `WaitFor.healthy`, `WaitFor.port`, `WaitFor.httpOk`,
  `WaitFor.logMessage` and `WaitFor.all`. A strategy is pure data, so a spec
  stays const-constructible and can be hashed.
- `ContainerSpec.healthcheck` injects a healthcheck into an image that ships
  none, which is most of them.
- Mounted files are folded into the configuration hash **by content**, not by
  path, so replacing a mounted certificate stops matching the container that
  is still serving the old one.
- `ContainerLease.exec` runs a command in the container and throws
  `ExecFailed` on a non-zero exit unless you ask otherwise.
  `ContainerLease.logTail` reads the log.
- `Lifetime.dedicated` opts a suite out of sharing.
- Talks to the Docker Engine API over its Unix socket directly. No Docker CLI,
  and no dependency beyond `crypto`, `meta`, `path` and `test`.
- Containers are deliberately left running between runs. `rig_cli` provides
  the `rig` command to list and remove them.
- `ContainerBuild.context` may contain a `.dockerignore`; rig interprets it
  client-side before sending the build context, since the daemon does not.
  The file named by `ContainerBuild.dockerfile` is always sent even if
  `.dockerignore` excludes it. A pattern rig cannot interpret (currently a
  character class such as `[a-z]`) throws rather than being sent anyway.
- `StateDir.markerDir(kind)` replaces `StateDir.suitesDir`: every module that
  records what it holds inside a container now files its markers under
  `markers/<kind>/<containerId>/<name>`, so `rig prune` can sweep them all
  without knowing what any kind means. `kind` is validated as a plain
  lowercase token (letters, digits, `_`, `-`) so it cannot be used to escape
  the state directory as a path segment.
