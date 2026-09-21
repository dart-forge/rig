## 0.4.0

- No functional change in this package. It moves to `rig: ^0.4.0`, because
  `^0.3.0` does not admit rig 0.4.0 and would otherwise hold you to rig 0.3.x.

## 0.3.0

- No behavior change. `rig prune`'s decision logic moved into `rig` as
  `pruneContainers()`; `runPrune` now only calls it and formats the
  `PruneResult` it gets back. Kept here: the output wording, the
  shared/dedicated breakdown line, the still-in-use network line, and
  `--older-than` parsing.

## 0.2.0

No functional change in this package. It moves to `rig: ^0.2.0`, because
`^0.1.0` does not admit rig 0.2.0 and would otherwise hold you to rig 0.1.x.

One consequence is worth knowing: rig 0.2.0 changes every configuration hash,
so the containers 0.1.0 left running are not reused. The first run on this
version creates fresh ones and leaves the old ones behind; `rig prune` clears
them.

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
