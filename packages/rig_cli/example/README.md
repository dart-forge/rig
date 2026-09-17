# Example

This package is a command, so its example is the commands themselves.

```bash
# What rig is holding right now, with the configuration hash that identifies
# each container, its state, lifetime, age and the project that created it.
rig ls

# Remove shared containers older than the cutoff. Never touches a dedicated
# container, so it cannot take away a server a suite asked to have to itself.
rig prune
rig prune --older-than 1h

# Remove every container rig made, regardless of age or lifetime, without
# checking whether anything is using one. Run it when no tests are running.
rig prune --all

# Remove only what a readiness failure left behind.
rig prune --failed
```

See [the package README](../README.md) for what each flag actually removes,
and why a bare `rig prune` is not safe by construction — container age is when
Docker created it, not when it was last used.
