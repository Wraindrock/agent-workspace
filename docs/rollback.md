# Rollback and lifecycle

agent-workspace inherits its safety story from bootc: **the operating system is an
image, every update is a new deployment, and the previous deployment is never
deleted to make room.**

## Deployments, not upgrades

```text
bootc status
  booted    ghcr.io/wraindrock/agent-workspace:latest   (deployment A)
  staged    ghcr.io/wraindrock/agent-workspace:latest   (deployment B, new digest)
  rollback  deployment A
```

An update is downloaded, laid out as a new deployment, and only becomes active
after a reboot. Nothing on the running system is mutated while it runs, so a
half-finished update cannot leave you with a machine that is neither version.

## The commands

| Command | What it does | Needs |
| --- | --- | --- |
| `agent-workspace status` | booted / staged / rollback deployments, pin state | bootc |
| `agent-workspace update` | stage the newest build of the current tag | root, bootc |
| `agent-workspace switch <tag>` | stage a different tag (`20261013`, `previous`, ...) | root, bootc |
| `agent-workspace rollback` | stage the previously booted deployment | root, bootc |
| `agent-workspace pin` | freeze this machine to the booted digest | root, bootc, jq |
| `agent-workspace pin --clear` | unfreeze | root |

All of them are also exposed on the host as `scripts/*.sh`, in case the image CLI
is unavailable (rescue environments, plain containers).

## Rollback drill

Run this once on a new machine, before you need it:

~~~bash
agent-workspace status          # note the booted digest
agent-workspace update          # stage something new
sudo systemctl reboot
agent-workspace status          # confirm the new deployment is booted
agent-workspace rollback        # stage the old one
sudo systemctl reboot
agent-workspace status          # you are back; nothing was lost
```

`rollback` is not a destructive "reset": it re-points the bootloader at the
previous deployment and marks the current one as the rollback target. Running it
again rolls *forward* to the deployment you just left.

## Pinning a machine

A tag like `latest` moves. For machines where "moves" is a hazard - a lab box
running a long evaluation, a demo machine - pin the digest:

~~~bash
agent-workspace pin            # writes /etc/agent-workspace/pinned-digest
agent-workspace update         # now targets that digest, not the moving tag
agent-workspace pin --clear    # rejoin the moving tag
```

```text
image   : ghcr.io/wraindrock/agent-workspace:latest
pinned  : sha256:9f2c...ab41
```

While a pin exists, `agent-workspace switch` refuses to run (unless you pass
`--ignore-pin`) rather than silently violating the pin.

## Tags published by CI

| Tag | Meaning | Use |
| --- | --- | --- |
| `latest` | newest build of the default branch | fleets that want updates |
| `previous` | whatever `:latest` pointed at before this release | one-tag fleet rollback |
| `YYYYMMDD` | daily build | reproducible installs |
| `YYYYMMDD-<sha>` | that day's build of a specific commit | forensics, bisecting |

Daily rebuilds exist because the base image moves: the same commit built next week
picks up Fedora security fixes.

## When something goes wrong

| Symptom | Action |
| --- | --- |
| New deployment misbehaves | `agent-workspace rollback` + reboot |
| Machine will not boot | pick the previous deployment in the bootloader menu (bootc keeps it as an entry) |
| Fleet-wide bad release | move the fleet to `:previous`, then pin while you investigate |
| Agent binary missing after update | `agent-workspace doctor --strict`; a module was turned off in `config/modules.conf` |
| Need to inspect an old build | `podman run --rm -it --entrypoint /bin/bash <tag>` |

## What rollback does *not* cover

- **Your data.** `/var` and `/home` are untouched by deployments, so a rollback
  does not undo a data migration. Version your data formats and migrations in the
  workload, not in the image.
- **`/etc/` overrides.** bootc merges `/etc` three ways; a hand edit survives
  updates by design, which also means it is not rolled back. Keep machine
  configuration in `/etc/agent-workspace/config.env` so it stays visible.
- **Container images pulled at runtime.** `podman` state in `/var/lib/containers`
  is not part of a deployment.
