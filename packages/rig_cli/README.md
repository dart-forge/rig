# rig_cli

The `rig` command: see what [rig](../rig) left running, and clean it up.

rig does not stop the containers it starts. Stopping one would pull it out
from under another suite that is sharing it, and leaving it means the next run
starts in about a second instead of paying startup again. The consequence is
that cleanup is a separate, explicit act — this is the tool for it.

## rig ls

What is running, with the configuration hash that identifies it, its age, and
the project that created it.

```
HASH              SUMMARY                              STATE    LIFETIME  AGE  PROJECT
180736060ca91cf6  postgres:16-alpine ports=5432 env=…   running  shared    3h   aim_postgres
```

The hash is how suites find a container to share: two suites whose
configuration hashes alike get the same container. Several containers can
carry one hash — a running one is preferred, and a stopped one is started and
reused rather than replaced, because restarting is cheaper than creating and
keeps whatever a previous run left inside. Only `shared` containers are
matched this way; a dedicated one is never handed to another suite.

A container whose project is not yours is normal. The hash identifies a
container, not who asked for it first.

## rig prune

```bash
rig prune                      # shared containers older than 7 days
rig prune --older-than 1h      # a shorter cutoff
rig prune --all                # everything rig created, regardless of age
rig prune --failed             # only the leftovers of runs that failed
```

Plain `rig prune` never touches a dedicated container, so it cannot take away
a server a suite asked to have to itself. It is not otherwise safe by
construction, and the reason is worth knowing: **age is when Docker created
the container, not when it was last used** — Docker exposes no such time — so
a bare prune can remove a shared container a suite is using right now, if
that container happens to be older than the cutoff. Seven days makes that
unlikely, not impossible.

`--all` drops the age check and the dedicated exemption both, and does not
look at whether anything is using a container. Run it when no tests are
running.

`--failed` wins over `--all` when both are given.

Pruning also collects the marker files modules leave behind to claim
resources inside a shared container, so a module's own bookkeeping does not
outlive the containers it refers to.

## Status

In development, not yet published to pub.dev. Until then, install it from a
checkout:

```bash
dart pub global activate -s path path/to/rig/packages/rig_cli
```
