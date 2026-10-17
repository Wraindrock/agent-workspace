# Architecture

agent-workspace is a *system container*: an OCI image that is also a complete
operating system. A container started from it has its own PID 1, systemd, users,
package database and SELinux policy, so one container is one machine dedicated to
one agent. That is the whole point: whatever an agent installs, breaks, or fills
up stays inside a container you can delete.

The image is a bootc image as well, so it can also be installed on hardware. That
is a supported but secondary path; everything below assumes the container.

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
| `runtime/` | the in-image CLI and first-boot script | yes, copied by the `install_runtime` pipeline step |
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
verify_layout                 # /home, /opt, /usr/local and /root must not be dangling
~~~

Each module is a directory with two files:

```text
build_files/modules/20-container-tools/
  module.env    MODULE_NAME, MODULE_DESCRIPTION, MODULE_ENABLED_DEFAULT
  install.sh    executable; run with MODULE_NAME/MODULE_DIR exported
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
| `/usr/share/agent-workspace/manifest.json` | JSON: image, version, base image, Fedora release, the module names, the installed agents with their binaries, titles and credential variables (`agentBinaries`, `agentCatalog`), toolchain versions, build timestamp |
| `/usr/share/agent-workspace/modules.txt` | newline-separated module names, for tools that do not want JSON |

`/etc/agent-workspace/build.env` carries the same identity as shell variables, so
the CLI can read it without `jq`. Because the manifest is *inside* the image, a
deployed machine can always explain itself:

~~~bash
agent-workspace manifest | jq '.modules, .agents, .agentCatalog'
~~~

and `agent-workspace doctor --strict` can fail when the running container no longer
matches that declaration.

## Layering: what goes where

| Layer | Contents | Survives `install.sh upgrade`? | Writable at runtime? |
| --- | --- | --- | --- |
| image layer (ostree) | everything the modules install | no: the new image replaces it | no |
| container layer | `/etc`, `/var` and `/usr/local` - whatever the agent installed or edited while running | no (capture it with `install.sh snapshot` first) | yes |
| named volume | `/home/agent`, the agent's home and working directory | yes: the volume outlives the container | yes |

There is deliberately no host bind mount in that table. An instance's data lives
inside the instance's own storage - the named volume for `podman`/`docker`, the
instance disk plus its installer-managed home directory for `incus` - so the
host's `--workspace` field is recorded for compatibility but never acted on.
Nothing on the host is shared into the agent's working tree. The installer's own
state (credentials, backend choice, metadata, snapshots) stays on the host under
`~/.config` and `~/.local/share`.

The practical rule: **declaration and the agent's code both live in storage the
installer controls, and the agent's persistent state lives in its home volume.**
Anything a module installs must land in the image; anything the agent produces
lands under `/home/agent`, which is what `snapshot`, `rollback` and `fork` carry,
and what `backup`/`restore` archive and verify.

The default DSH plugin set is the one deliberate exception, and it is worth naming
because it looks like a violation: the plugin set is installed into the image
(`45-dsh-plugins`, at `/usr/share/agent-workspace/dsh/profiles/web`) but DSH only
reads profiles from the agent's home, which is in the volume. The set is therefore
*seeded* into `/home/agent/.dsh/profiles/web` on first boot, and firstboot is where
the interesting decision lives: seed what is missing, refresh what the image owns
when the shipped plugin-set digest changes, and leave everything else - above all
the user's `cordis.patch.yml` - exactly as it is. The image owns the set; the volume
keeps it; the digest in `/usr/share/agent-workspace/dsh/profiles.version` is what
lets the two agree across an upgrade. Implementation: `runtime/lib/dsh-profile.sh`.

## Runtime components

| Component | Path | Role |
| --- | --- | --- |
| `agent-workspace` | `/usr/bin/agent-workspace` | dispatcher for all subcommands |
| `common.sh` | `/usr/lib/agent-workspace/` | shared helpers sourced by the dispatcher and its subcommands |
| `cmd-info.sh` | `/usr/lib/agent-workspace/` | `version`, `manifest`, `modules`, `agents` |
| `cmd-status.sh` | `/usr/lib/agent-workspace/` | instance identity: container vs booted system, image, agent user, harnesses |
| `cmd-doctor.sh` | `/usr/lib/agent-workspace/` | declaration-vs-reality checks |
| `firstboot.sh` | `/usr/lib/agent-workspace/` | one-shot machine provisioning |
| `dsh-profile.sh` | `/usr/lib/agent-workspace/` | seeds/refreshes the image's DSH plugin set into the agent's home; sourced by `firstboot.sh` |

The CLI sources its libraries from `${AGENT_WORKSPACE_LIB:-/usr/lib/agent-workspace}`,
so running it from a checkout is enough to exercise a change:

~~~bash
AGENT_WORKSPACE_LIB="$PWD/runtime/lib" ./runtime/bin/agent-workspace version
~~~

### Container vs booted system

`is_container()` checks `/run/.containerenv` and `/.dockerenv`, and
`agent-workspace status` reports the answer as `mode: container` or `mode: process`.
The same binary is therefore safe in CI containers, in `podman run` sessions,
and on a booted host - it reports what it is instead of assuming.

## Publishing an agent's web UI

`dsh web` refuses to bind anything but loopback, on purpose: the UI can run code, so
`--host 0.0.0.0` is rejected by the CLI. A container's loopback is also not reachable
from the host through a port mapping alone. The image therefore carries one overlay,
`/usr/share/agent-workspace/dsh-web.yml`, which the installer passes as
`dsh web --patch`. It replaces exactly one profile entry - `id: webserver` - with
`host: 0.0.0.0` and `port: 3080`, so the UI listens on the container's own
interfaces. A patch replaces the matched entry's `config` object as a whole, which is
why both keys are present rather than only the host.

The host side stays closed and boring: `create` publishes
`127.0.0.1:<host port>:3080` and nothing else, and records the port with the
container so `rollback`, `recover` and `upgrade` reproduce the same mapping.
Starting the UI is the installer's job, not the image's: `create` waits for the
container's first boot - the agent user is what the UI runs as - and then calls the
same helper as `install.sh web NAME`, which starts the UI as that user, waits for the
published port to answer, reads the one-time token out of the UI's log, and prints the
local URL; the first request from a browser trades that token for a 30-day cookie.
`start`, `restart`, `recover`, `rollback`, `fork` and `upgrade` call it too whenever
they leave a container running, because the UI is a process in the container and a
published port with nothing behind it answers with a connection reset.

Binding inside the container instead of joining the host network is deliberate: the
container keeps its own network namespace, the mapping only ever touches host
loopback, and anything wider (a LAN name, a reverse proxy, TLS) stays a host-side
decision.

## System integration

| File | Purpose |
| --- | --- |
| `agent-workspace-firstboot.service` | creates the agent user, sub-ids, linger; guarded by `ConditionPathExists=!/var/lib/agent-workspace/.provisioned` so it runs exactly once per machine |
| `agent-workspace-health.timer` / `.service` | daily `agent-workspace doctor --quiet` |
| `90-agent-workspace.preset` | keeps the units' enabled state stable across updates |
| `00-agent-workspace.conf` | unqualified-search-registries and permissive short names for podman |
| `agent-workspace.sh` | `profile.d` aliases and `PATH` additions |

There is deliberately no `sysctl.d` drop-in. The image used to ship one, and it
could not work: the kernel charges inotify instances per *uid*, so a container
reads the host session's value rather than the image's, while `vm.max_map_count`
is per-namespace and `net.*` already gets a private namespace per container. The
engine rejects the non-namespaced keys outright (`sysctl
'fs.inotify.max_user_instances' is not allowed`), so the container cannot set them
for itself either. What is left is the host's business, which is why `install.sh`
never writes to `/etc/sysctl.d` and `tests/smoke.sh` asserts the file is *absent*
rather than present. The values the drop-in named - inotify watches and instances,
`vm.max_map_count`, `somaxconn` - are set by the kernel defaults, the engine, or
the host administrator; this project neither sets nor relies on them.

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

`install.sh` at the repository root is the other half of the contract, and the
supported entry point of the whole project. It runs on the *host*, never enters the
image, and turns one published image into independent agent containers:

~~~bash
./install.sh                        # interactive TUI
./install.sh create --file boxes.conf --yes
./install.sh list
./install.sh snapshot dsh-box --label before-refactor
~~~

It is split the same way the image build is: `install.sh` parses arguments and
dispatches, and one library per concern does the work.

| Library | Role |
| --- | --- |
| `installer/lib/ui.sh` | the gum TUI (the menu needs gum and a terminal); individual prompts fall back to plain `read` when gum is missing |
| `installer/lib/engine.sh` | the backend loader: detection and the ready check for each backend, the `auto` order (incus, podman, docker), the verb dispatching and a dry-run mode that prints commands instead of running them |
| `installer/lib/backend-*.sh` | one file per backend - `backend-container-cli.sh` is the shared podman/docker implementation, `backend-podman.sh` and `backend-docker.sh` own the flags that boot systemd, `backend-incus.sh` implements the whole interface against `incus` |
| `installer/lib/state.sh` | where host state lives: `meta`, snapshots, and credential files |
| `installer/lib/agents.sh` | the agent catalog, read from the image manifest and merged over the built-in table |
| `installer/lib/commands.sh` | `create`, `list`, `start`, `stop`, `restart`, `enter`, `shell`, `logs`, `snapshot`, `snapshots`, `rollback`, `recover`, `fork`, `upgrade`, `web`, `remove`, `doctor` |

| Decision | Made by |
| --- | --- |
| which engine | `--engine podman|docker`, otherwise podman if both are present |
| which image | `--image` (default taken from `image.env`) |
| how many containers, and their names | the TUI, `--name`, `--count`, or a declaration file |
| which agent each container runs | the built-in `dsh` and `opencode` table, with the agent catalog from the image manifest merged over it |
| persistent or ephemeral | `--mode persistent|ephemeral` |
| credentials | a `0600` env file per container under `~/.config/agent-workspace/containers/` |
| host state | `~/.local/share/agent-workspace/` (per-container `meta` plus snapshot archives) |

Every container it creates carries the labels `agent-workspace.manager=install.sh`,
`agent-workspace.agent` and `agent-workspace.mode`, so `list`, `doctor` and
`remove` only ever touch containers this installer owns.

### Rollback lives on the host, not in the image

A snapshot commits the container's filesystem into a local image
(`agent-workspace/snapshot-<name>:<id>`) and archives `/home/agent` into
`~/.local/share/agent-workspace/snapshots/<name>/<id>/home.tar.gz`. `rollback`
recreates the container from that snapshot; `recover` starts, restores, or rebuilds
a container that is missing; `fork` copies a container into a second one; and
`upgrade` takes a `pre-upgrade` snapshot before it pulls anything, so a bad image
is one `rollback` away. None of this touches the host system. The full semantics
are in `docs/rollback.md`.

## Deliberate non-goals

- **No configuration management at runtime.** If something must be true for every
  machine, it belongs in a module, not in a first-boot script.
- **No package drift.** `dnf` works inside a running container for
  experimentation, but the next `install.sh upgrade` replaces it; the image is
  the only durable place.
- **No copied upstream scaffolding.** The pipeline is written for this project so
  that the whole repository can carry one licence (MIT).
- **No host kernel tuning, and no `sudo` for it.** The project targets many Linux
  distributions and cannot assume a particular host kernel configuration, desktop
  session or administrator. It sets no `sysctl` values anywhere - not in the
  image, not through `install.sh`, and not as a documented workaround - and it
  does not require the host to be tuned before a container boots. `tests/smoke.sh`
  asserts the absence of the sysctl drop-in rather than its presence, and
  `tests/integration.sh` diagnoses an exhausted inotify budget by reporting the
  host's own numbers without asking for a kernel change. When a host setting is
  genuinely too small (inotify instances shared per *uid*, shared with the desktop
  session), the answer is to run the container from a session with budget to
  spare - not to make the project's installation depend on the host's kernel
  parameters.
- **No distrobox or toolbox images.** The image runs systemd as PID 1 and
  `install.sh` is the only supported way to run it; a distrobox container that
  boots systemd competes for the same per-uid inotify budget as anything else
  that boots systemd, which is a host limit and not something the image can fix
  (see [containers.md](containers.md#troubleshooting)).
