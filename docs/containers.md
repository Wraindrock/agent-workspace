# Containers on your host

This project has exactly one supported way to be used: you run `./install.sh` on a
Linux machine, it walks you through a TUI, and it creates containers on that machine.
Each container is a complete operating system with a pre-configured agent inside it,
isolated from your workstation and from every other container.

```bash
git clone https://github.com/wraindrock/agent-workspace && cd agent-workspace
./install.sh
```

The installer is the whole interface: creating, entering, snapshotting, rolling back,
recovering, forking, upgrading and removing containers. It never needs root.

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
