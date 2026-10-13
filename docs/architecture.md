# Architecture

agent-workspace is a *system container*: an OCI image that is also a bootable
operating system. The same artifact is a container you can `podman run` and a
machine you can `bootc switch` to. Everything below follows from that duality.

## The build contract

```text
                     image.env            config/*.conf
                         |                     |
                         v                     v
  Containerfile --> [ context stage ] --> [ module pipeline ] --> bootc image
                         |                     |                      |
              build_files/ config/        system_files/          manifest.json
              runtime/  system_files/     runtime/               build.env
```

### 1. Context stage

`FROM scratch AS ctx` copies four repository trees into `/ctx`:

| Tree | Purpose | Lands in the image? |
| --- | --- | --- |
| `build_files/` | the module pipeline and its libraries | no (only the manifest it produces) |
| `config/` | the declarative switches | no (values are recorded in the manifest) |
| `runtime/` | the in-image CLI and first-boot script | yes, via the runtime module |
| `system_files/` | verbatim overlay copied to `/` | yes |

Keeping the build inputs in a separate stage means the image never ships its own
build scripts, and `COPY` of the repository root is impossible: the build can only
see these four trees. A `--mount=type=bind,from=ctx` mount exposes them to the
single `RUN` that runs the pipeline.

### 2. Module pipeline

`build_files/build.sh` is the only entry point. It runs as root, requires `dnf5`,
and executes in this order:

~~~bash
require_root; require_command dnf5
prepare_state                 # STATE_DIR=/run/agent-workspace
overlay_system_files          # cp -avf /ctx/system_files/. /
install_runtime               # runtime/lib -> /usr/lib/agent-workspace
                              # runtime/bin -> /usr/bin
run_modules                   # build_files/modules/*/ in filename order
summarize
```

Each module is a directory with two files:

```text
build_files/modules/20-container-tools/
  module.env    MODULE_NAME, MODULE_DESCRIPTION, MODULE_ENABLED_DEFAULT
  install.sh    install_module() { ... }
```

### 3. How a module decides whether to run

The pipeline resolves three sources of truth, in this order:

1. **`IMAGE_MODULES` build argument.** ```IMAGE_MODULES=all``` (the default) leaves
   the decision to the config files. A comma-separated list (```IMAGE_MODULES=10-base-packages,20-container-tools```)
   builds a narrow image and ignores `config/modules.conf` entirely.
2. **`config/modules.conf`.** `name=1` forces a module on, `name=0` forces it off.
   Anything unlisted falls through to the next step.
3. **`MODULE_ENABLED_DEFAULT`.** The module's own default.

This gives three levels of control - a one-off build flag, a repository-wide
declaration, and a per-module default - without any of them silently overriding
another.

### 4. The manifest is the contract

`80-manifest` writes two files inside the image:

| Path | Contents |
| --- | --- |
| `/usr/share/agent-workspace/manifest.json` | JSON: image, version, base image, Fedora release, modules with descriptions, the installed agents with their binaries, titles and credential variables (`agentBinaries`, `agentCatalog`), toolchain versions, build timestamp |
| `/usr/share/agent-workspace/modules.txt` | newline-separated module names, for tools that do not want JSON |

`/etc/agent-workspace/build.env` carries the same identity as shell variables, so
the CLI can read it without `jq`. Because the manifest is *inside* the image, a
deployed machine can always explain itself:

~~~bash
agent-workspace manifest | jq '.modules, .agents, .agentCatalog'
~~~

and `agent-workspace doctor --strict` can fail when the running system no longer
matches that declaration.

## Layering: what goes where

| Layer | Contents | Survives image update? | Writable at runtime? |
| --- | --- | --- | --- |
| container image (ostree) | everything the modules install | replaced by the new deployment | no |
| `/etc` | `/etc/agent-workspace/config.env`, operator config | yes, three-way merged | yes |
| `/var` | caches, container storage, `/var/lib/agent-workspace` | untouched by updates | yes |
| `/usr/local` | `uv`, pipx-installed binaries, manual installs | yes for `/usr/local` on bootc systems | yes |

The practical rule: **declaration lives in the image, state lives in `/var`,
operator overrides live in `/etc`.** Anything a module installs must land in the
image; anything that changes per machine must land in `/etc` or `/var`.

## Runtime components

| Component | Path | Role |
| --- | --- | --- |
| `agent-workspace` | `/usr/bin/agent-workspace` | dispatcher for all subcommands |
| `common.sh` | `/usr/lib/agent-workspace/` | shared helpers sourced by the dispatcher and its subcommands |
| `cmd-info.sh` | `/usr/lib/agent-workspace/` | `version`, `manifest`, `modules`, `agents` |
| `cmd-status.sh` | `/usr/lib/agent-workspace/` | bootc deployment status, container detection |
| `cmd-doctor.sh` | `/usr/lib/agent-workspace/` | declaration-vs-reality checks |
| `cmd-lifecycle.sh` | `/usr/lib/agent-workspace/` | `switch`, `rollback`, `update`, `pin` |
| `firstboot.sh` | `/usr/lib/agent-workspace/` | one-shot machine provisioning |

The CLI sources its libraries from `${AGENT_WORKSPACE_LIB:-/usr/lib/agent-workspace}`,
so running it from a checkout is enough to exercise a change:

~~~bash
AGENT_WORKSPACE_LIB="$PWD/runtime/lib" ./runtime/bin/agent-workspace version
~~~

### Container vs booted system

`is_container()` checks `/run/.containerenv` and `/.dockerenv`; `has_bootc()`
checks `bootc` on `PATH` **and** `/sysroot` being a mount point. Every lifecycle
command calls both before doing anything, so the same binary is safe in CI
containers, in `podman run` sessions, and on a booted host.

## System integration

| File | Purpose |
| --- | --- |
| `agent-workspace-firstboot.service` | creates the agent user, sub-ids, linger; guarded by `ConditionPathExists=!/var/lib/agent-workspace/.provisioned` so it runs exactly once per machine |
| `agent-workspace-health.timer` / `.service` | daily `agent-workspace doctor --quiet` |
| `90-agent-workspace.preset` | keeps the units' enabled state stable across updates |
| `00-agent-workspace.conf` | unqualified-search-registries and permissive short names for podman |
| `90-agent-workspace.conf` | inotify/mmap/socket sysctl tuning for many parallel agents |
| `agent-workspace.sh` | `profile.d` aliases and `PATH` additions |

## Base images

`BASE_IMAGE` is a build argument, so the platform is a one-line decision:

| Base | Use |
| --- | --- |
| `ghcr.io/ublue-os/base-main:latest` (default) | current Fedora + bootc, no desktop |
| `ghcr.io/ublue-os/base-main:gts` | slower-moving Fedora, recommended for fleets |
| `ghcr.io/ublue-os/bluefin:stable` | GNOME desktop base |
| `ghcr.io/ublue-os/aurora:stable` | KDE desktop base |
| `quay.io/fedora/fedora-bootc:44` | vanilla Fedora bootc, no extras |

Universal Blue images are themselves cosign-signed Fedora bootc images, which is
why the module pipeline can assume `dnf5` and `bootc` exist.

## The host installer

`install.sh` at the repository root is the other half of the contract. It runs on
the *host* - it never enters the image - and turns one published image into several
independent agent containers:

~~~bash
./install.sh                  # interactive wizard
./install.sh --file boxes.conf --yes
./install.sh --list
~~~

| Decision | Made by |
| --- | --- |
| which image | `--image` (default taken from `image.env`) |
| how many containers, and their names | the wizard, `--count`, `--name`, or a declaration file |
| which agent each container runs | the agent catalog in the image manifest, falling back to the built-in `dsh` and `opencode` table |
| persistent or ephemeral | `--mode persistent|ephemeral` |
| credentials | a `0600` env file per container under `~/.config/agent-workspace/containers/` |

Every container it creates carries the labels `agent-workspace.manager=install.sh`,
`agent-workspace.agent` and `agent-workspace.mode`, so `--list`, `--verify` and
`--remove` only ever touch containers this installer owns. See `docs/containers.md`.

## Deliberate non-goals

- **No configuration management at runtime.** If something must be true for every
  machine, it belongs in a module, not in a first-boot script.
- **No package drift.** `dnf` works on a booted system for experimentation, but
  the next deployment replaces it; the image is the only durable place.
- **No copied upstream scaffolding.** The pipeline is written for this project so
  that the whole repository can carry one licence (MIT).
