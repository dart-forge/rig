## 0.1.0

First release.

- `rig ls` lists the containers rig is holding, with the configuration hash
  that identifies each one, its state, lifetime, age and the project that
  created it.
- `rig prune` removes shared containers past a cutoff (`--older-than`,
  seven days by default) and dedicated containers past a fixed one hour —
  long enough to outlive any plausible test suite, so a dedicated container
  still there is a leak from a suite killed before teardown ran. Age is when
  Docker created the container, not when it was last used, because Docker
  exposes no such time.
- `rig prune --all` removes every container rig created regardless of age or
  lifetime, without checking whether anything is using it.
- `rig prune --failed` removes only what a readiness failure left behind.
- Pruning also collects the marker files modules leave to claim resources
  inside a shared container, so that bookkeeping does not outlive the
  containers it refers to.
