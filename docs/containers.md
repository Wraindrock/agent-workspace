# Containers on your host

This project has exactly one supported way to be used: you run `install.sh` on a
Linux machine, it walks you through a TUI, and it creates containers on that machine.
Each container is a complete operating system with a pre-configured agent inside it,
isolated from your workstation and from every other container.

```bash
curl -fsSL https://raw.githubusercontent.com/wraindrock/agent-workspace/main/install.sh | bash
```

There is no clone step: the script fetches the libraries it needs and verifies each one
against a digest carried inside itself (see [Install methods](#install-methods) below).

The installer is the whole interface: creating, entering, snapshotting, rolling back,
recovering, forking, upgrading and removing containers. It never needs root.

## Install methods

`install.sh` works the same three ways, and only the first is the documented default:

| How | Command | Notes |
| --- | --- | --- |
| Piped, no checkout | `curl -fsSL .../main/install.sh \| bash` | The supported install. Fetched files are cached under `~/.cache/agent-workspace/bootstrap/`. |
| Checkout | `git clone ... && cd agent-workspace && ./install.sh` | Used as-is; the installer itself needs no network. |
| Off a branch | `curl .../dev/install.sh \| AW_INSTALL_REF=dev bash` | `dev` receives work before `main`. |

Nothing is installed system-wide and nothing needs root: the installer is a script, and
everything it creates lives under your home directory (`~/.local/share/agent-workspace`
for container state, `~/.config/agent-workspace` for configuration).

### Why the digests, and what a refusal means

A piped install has no repository to compare against, so `install.sh` carries the SHA-256
of every file it downloads and refuses anything that does not match:

```text
checksum mismatch for installer/lib/commands.sh from ref 'main':
expected <digest>, got <digest>. Refusing this file; nothing was installed from it.
```

That message means the bytes served were not the bytes this script was built from. It is
not a warning and there is no override flag: the offending file is never written, and
re-running fails the same way until the mirror and the script agree again. Files fetched
*before* the bad one have already been verified and cached - they are the ones the script
expects, so the installer is never left running half of one tree and half of another. Two
causes are worth telling apart:

* **You mixed refs** - a `main` script asked to fetch `dev` files (or the reverse). Each
  branch stamps its own digests, so this is a refusal by design, not a bug. Use one ref
  for both the URL and `AW_INSTALL_REF`.
* **A stale stamp** - you are running a script that does not match the files it fetches.
  On a checkout this cannot happen (a checkout is used as-is, with no fetch at all). If
  you hit it while *developing*, you edited `installer/lib/*` or `image.env` without
  re-stamping: run `just stamp`. `just check` and CI both fail on a stale stamp, so a
  release cannot ship this way.

Environment variables on the piped path: `AW_INSTALL_REF` (branch to fetch; default
`main`) and `AW_INSTALL_BASE_URL` (URL prefix, for a mirror). `AW_BOOTSTRAP_DOWNLOAD` is a
**test seam**, not a feature - it replaces the downloader so `tests/bootstrap.sh` can
assert that a mismatched file is refused without a network. Leave it unset.


## Requirements

* `podman` or `docker` - rootless podman is the recommended setup (`docker` is
  supported by using a privileged container with its own cgroups namespace)
* `bash` 4.4 or newer
* an image that can be pulled - `ghcr.io/wraindrock/agent-workspace:latest` unless
  `image.env` or `--image` says otherwise
* optional: `gum` for the nicer TUI. It is offered for download on first
  interactive use when missing; without it every prompt falls back to plain
  `read` questions.

## The TUI

Running `./install.sh` with no arguments opens a menu:

```
Create a container
List containers
Enter a container (run its agent)
Open a shell in a container
Open the agent's web UI
Show the log of a container
Start / restart a container
Stop a container
Snapshot a container
List snapshots
Roll a container back
Recover a container
Fork a container
Upgrade a container to a newer image
Run the doctor
Remove a container
Quit
```

The create flow asks for the agent, the container name, the lifecycle (persistent or
ephemeral), the host workspace directory, and the credential the agent needs. Pass
`--no-tui` to refuse to prompt, which is what scripts and CI want.

## Lifecycles

`persistent` (the default) starts a detached container whose PID 1 is systemd and
whose `/home/agent` is a named volume, so the agent's state survives restarts:

```bash
./install.sh enter dsh-box     # start the agent inside the container
./install.sh shell dsh-box     # get a login shell instead
./install.sh stop dsh-box      # stop it without deleting it
./install.sh start dsh-box     # bring it back
```

Under podman the container is created with `--systemd=always --restart unless-stopped`.
Under docker it needs `--privileged --cgroupns=host`, a read-write
`/sys/fs/cgroup` mount and tmpfs mounts for `/run` and `/tmp`, because the image
boots a real init system.

`ephemeral` runs the agent once and throws the container away when it exits
(`--rm`); the installer still records it so `list`, `logs` and `doctor` know about it.

## The agent's web UI

DeepSeek Harness ships a web UI. `dsh web` on its own listens on loopback only, and a
container's loopback is unreachable from the host, so the image carries a small
overlay that lets the UI listen inside the container; the installer then publishes
that port on the host's loopback only, as `127.0.0.1:<host port>:3080`.

~~~bash
./install.sh web dsh-box
~~~

`web` starts `dsh web` inside the container as the agent user, waits for it to come
up and prints a one-time link:

~~~
✓ dsh web UI is published on http://127.0.0.1:34700/ (container port 3080)
  open: http://127.0.0.1:34700/?token=...
  the token sets a 30-day cookie in that browser, so the link is not needed again
~~~

The host port is picked from the first free one at or above 3080 when the container is
created, and it is recorded with the container, so `rollback`, `recover` and
`upgrade` keep the same URL; `fork` gets a new one of its own. Pick a port yourself
with `./install.sh create --web-port 8080`, or leave the container without a published
port with `--no-web`. The port is only ever bound to `127.0.0.1` on the host; reach it
from another machine through your own tunnel if you need that.

The image ships the `dsh` overlay that makes this possible
(`/usr/share/agent-workspace/dsh-web.yml`), because `dsh web` refuses to bind
anything but loopback by default. Only agents with a web UI the installer knows how to
start can be opened this way; anything else is refused with a plain message.

## Non-interactive use

Every TUI action has a subcommand:

~~~bash
./install.sh create --agent dsh --name dsh-box --workspace "$PWD"   # one container
./install.sh create --agent opencode --name box --count 2           # box-1, box-2
./install.sh list                                                   # what this host has
./install.sh snapshot dsh-box --label before-refactor --keep 10
./install.sh snapshots dsh-box
./install.sh rollback dsh-box --to 20260113T090000Z
./install.sh rollback dsh-box --skip-safety                 # keep no pre-rollback snapshot
./install.sh recover dsh-box
./install.sh web dsh-box                                             # open the agent's web UI
./install.sh fork dsh-box dsh-fork --agent opencode
./install.sh upgrade dsh-box --image ghcr.io/wraindrock/agent-workspace:latest
./install.sh remove dsh-box --purge-snapshots
./install.sh doctor --strict
./install.sh --help
```

Global options: `--engine auto|podman|docker`, `--image REF`, `--no-tui`,
`--dry-run` (print the engine commands instead of running them), `--no-pull`,
`--yes`, `--quiet`.

## Declarative containers

A set of containers can be written down, which makes it reproducible on another host:

```
# name       agent     lifecycle   workspace
review-box   dsh       persistent  ~/work/review
scratch      opencode  ephemeral
```

```bash
./install.sh create --file containers.conf               # create them
./install.sh create --file containers.conf --dry-run     # only show the commands
./install.sh create --file containers.conf --save saved.conf
```

Lines are `name agent [mode] [workspace]`; blank lines and `#` comments are ignored,
and `mode`/`workspace` fall back to `persistent` and `~/agent-workspace/<name>`.
Use `--file -` to read the declaration from stdin, and `--save FILE` to write back
what you created (the TUI offers the same thing when you create several containers).

## Which agents a container can run

The image decides. `/usr/share/agent-workspace/manifest.json` inside the image
carries an `agentCatalog` that lists, for every agent the build installed, its
command, its label and the environment variable that holds its credential.
`./install.sh --help-agents` prints the installer's built-in table and needs no
engine. When a container image can be inspected, the image's catalog is merged
over that table, so the menu picks up agents the build added. Turning an agent
on or off is a build-time decision: `config/agents.conf` (see [agents.md](agents.md)).

## Credentials

Each container gets its own environment file,
`~/.config/agent-workspace/containers/<name>.env`, written with mode `600` and passed
to the engine with `--env-file`. Values are taken from your environment when they are
already exported (`DEEPSEEK_API_KEY`), otherwise the installer asks for them (and
skips the prompt when there is no terminal). `--env KEY=VALUE` adds one explicitly.
Nothing is baked into an image, and nothing lands in the workspace or in a snapshot.
`fork` copies the source container's file and warns you to review it.

## What the installer keeps on this host

| Path | Content |
| --- | --- |
| `~/.config/agent-workspace/containers/<name>.env` | the container's credentials, mode 600 |
| `~/.local/share/agent-workspace/containers/<name>/meta` | engine, agent, mode, workspace, volume, image, web port, timestamps |
| `~/.local/share/agent-workspace/containers/<name>/meta.history` | one line per lifecycle event |
| `~/.local/share/agent-workspace/snapshots/<name>/<id>/` | `meta` plus `home.tar.gz` (see [rollback.md](rollback.md)) |

`XDG_CONFIG_HOME` and `XDG_DATA_HOME` are honoured. `list`, `doctor` and `remove`
work from the host state directory, not from the engine. Containers created here
also carry the label `agent-workspace.manager=install.sh`, which engine-side
checks use to recognise them - for example when deciding whether a snapshot
image is still in use.

## Doctor

`install.sh doctor` checks the engine, the recorded containers and their volumes, each
container's recorded run image, the credential files (they must be mode `600`) and the
snapshot archives (they must be readable tarballs), and for containers created with a web UI,
that the host port is still published. It never changes anything; it is the check to
run before you need a rollback. `--strict` exits non-zero when anything is
wrong, which is what the test suite uses.

## Troubleshooting

### A container exits immediately, or a systemd container stops mid-boot

Symptoms: `install.sh create` reports a container that is not running,
`install.sh logs <name>` is empty or ends at the boot, and inside any container
that boots systemd (including `distrobox create --init`) boot stops at:

```text
Failed to create control group inotify object: Too many open files
Failed to allocate manager object: Too many open files
[!!!!!!] Failed to allocate manager object.
Exiting PID 1...
```

Root cause: the kernel charges inotify instances per *uid*, not per container
(`fs.inotify.max_user_instances`, 128 on a default Fedora). Your desktop session
shares that budget with every container that boots systemd, and once it runs out
`pasta` and `conmon` log the same exhaustion when a container starts
(`inotify_init1(): Too many open files, use a timer`, `Failed to create inotify
fd`). This is a host limit, not an image defect, and it is not this project's to
fix: `fs.inotify.*` and `vm.max_map_count` are not namespaced, so an image cannot
set them for a container (the engine rejects those keys outright with `sysctl
'fs.inotify.max_user_instances' is not allowed`), and `install.sh` never writes to
`/etc/sysctl.d`. Any systemd container on the same desktop session fails the same
way; on a host that still has budget to spare this image boots as it is, with no
host tuning at all.

First decide whether the budget really is exhausted:

```bash
# the limit, and the kernel's own accounting of how much of it this uid spends
cat /proc/sys/fs/inotify/max_user_instances
find /proc/*/fd -lname anon_inode:inotify 2>/dev/null | wc -l
```

- **The count is near the limit** - the graphical session is holding the budget.
  Nothing inside the image can work around that, and raising it is not required
  by this project: start the container from a session that is not spending the
  whole budget (a TTY login rather than the desktop session is the usual way), or
  stop the other systemd containers competing for it. The budget is charged per
  *uid*, so a machine running several agents that each boot systemd needs roughly
  one instance per container on top of what the desktop session already spends.
- **The count is far below the limit** - inotify is not the problem, and the boot
  failed for another reason. Read `install.sh logs <name>` rather than tuning
  anything.

`tests/integration.sh` ("the container the installer creates actually runs")
detects the error string and prints this diagnosis instead of blaming the image.

### Distrobox and toolbox

The image is not a distrobox or toolbox image, and the project does not target
them: `install.sh` is the entry point and `tests/integration.sh` is the contract
for "the container runs". `distrobox create --image
ghcr.io/wraindrock/agent-workspace:latest --init` does start this image, but
`--init` boots systemd inside it, so it lands in the host inotify limit above
(the container exits 255 while the systemd boot fails).
