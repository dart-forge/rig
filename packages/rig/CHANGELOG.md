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
