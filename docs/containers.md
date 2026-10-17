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
ephemeral), and the credential the agent needs. It does not ask for a host directory:
all of the agent's data lives inside the instance's storage. Pass `--no-tui` to
refuse to prompt, which is what scripts and CI want.

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

The installer also starts the UI for you, because the UI is a process *inside* the
container: it dies whenever the container does, and a published port with nothing
behind it answers with a connection reset, which reads as "the container did not
start". `create` waits for the container's first boot (that is what creates the
agent user the UI runs as, up to `CONTAINER_FIRSTBOOT_TIMEOUT` seconds, 180 by
default) and then starts it; `start`, `restart`, `recover`, `rollback`, `fork` and
`upgrade` do the same whenever they leave a container running. When the UI comes up
you get a one-time link:

~~~
✓ dsh web UI is published on http://127.0.0.1:34700/ (container port 3080)
  open: http://127.0.0.1:34700/?token=...
  the token sets a 30-day cookie in that browser, so the link is not needed again
~~~

If the UI is not running - a container stopped outside the installer, or one whose
first boot had not finished when it was created - the same link comes from an
explicit command. This one fails loudly when the first boot is still going, instead
of printing a URL that does not answer:

~~~bash
./install.sh web dsh-box
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
start can be opened this way; anything else gets no published port at all (the
installer says so when `--web-port` asked for one), rather than a port that resets the
connection.

## Non-interactive use

Every TUI action has a subcommand:

~~~bash
./install.sh create --agent dsh --name dsh-box                      # one container
./install.sh create --agent opencode --name box --count 2           # box-1, box-2
./install.sh list                                                   # what this host has
./install.sh backup dsh-box --to /safe/dsh-box.tar.gz               # verified archive + manifest
./install.sh restore dsh-box /safe/dsh-box.tar.gz                   # instance must be stopped
./install.sh rescue dsh-box                                         # root shell; --copy PATH to get data out
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

Global options: `--backend NAME` (`--engine` is an alias), `--image REF`, `--no-tui`,
`--dry-run` (print the engine commands instead of running them), `--no-pull`
(use the local copy without refreshing its tag), `--yes`, `--quiet`.

## Declarative containers

A set of containers can be written down, which makes it reproducible on another host:

```
# name       agent     lifecycle
review-box   dsh       persistent
scratch      opencode  ephemeral
```

```bash
./install.sh create --file containers.conf               # create them
./install.sh create --file containers.conf --dry-run     # only show the commands
./install.sh create --file containers.conf --save saved.conf
```

Lines are `name agent [mode] [workspace]`; blank lines and `#` comments are ignored,
and `mode` falls back to `persistent`. The optional `workspace` column is accepted
for compatibility and recorded, but it is never mounted: instance data lives inside
the instance, not in a host folder.
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

`install.sh root <name> on` adds one more credential: the agent account's password, in
`~/.config/agent-workspace/credentials/<name>.root` (mode `600`). It is the login you
can use inside the instance while the in-instance-root switch is on; `off` deletes it
and rotates the password inside the instance. See "Root inside the instance" in the
[README](../README.md).

## What the installer keeps on this host

| Path | Content |
| --- | --- |
| `~/.config/agent-workspace/containers/<name>.env` | the container's credentials, mode 600 |
| `~/.config/agent-workspace/credentials/<name>.root` | the agent's password while in-instance root is on, mode 600 |
| `~/.local/share/agent-workspace/containers/<name>/meta` | engine, agent, mode, recorded workspace (compatibility only), volume, image, web port, timestamps |
| `~/.local/share/agent-workspace/containers/<name>/meta.history` | one line per lifecycle event |
| `~/.local/share/agent-workspace/snapshots/<name>/<id>/` | `meta` plus `home.tar.gz` (see [rollback.md](rollback.md)) |

`XDG_CONFIG_HOME` and `XDG_DATA_HOME` are honoured. `list`, `doctor` and `remove`
work from the host state directory, not from the engine. Containers created here
also carry the label `agent-workspace.manager=install.sh`, which engine-side
checks use to recognise them - for example when deciding whether a snapshot
image is still in use.

That table is the whole host-side surface. The agent's data is **not** there and
not in a bind-mounted folder: for `podman`/`docker` it is a named volume owned by
the engine, and for `incus` it is the instance disk plus the installer-managed
`~/.local/share/agent-workspace/incus/homes/<name>` directory. The engine volume is
still readable by your host user (rootless engines run as you), so it protects
against a damaged instance, not against the host user. Move it in and out with
`backup`, `restore` and `rescue`; see [Where the data lives](../README.md#where-the-data-lives-backup-restore-and-rescue).

## Doctor

`install.sh doctor` checks the engine, the recorded containers and their volumes, each
container's recorded run image, the credential files (they must be mode `600`) and the
snapshot archives (they must be readable tarballs), and for containers created with a web UI,
that the host port is still published. It never changes anything; it is the check to
run before you need a rollback. `--strict` exits non-zero when anything is
wrong, which is what the test suite uses.

## Backends

`install.sh` calls a fixed set of verbs (create, exec, logs, copy, remove, ...) and a
backend implements them, so the lifecycle, backup, fork and rollback commands behave
the same whichever one you use. **There is no `auto`**: the installer never probes the
host and picks for you, because that hides a trade-off only you can weigh.

- `--backend NAME` (`--engine` is an alias) chooses for this run; it is never written
  back over the remembered choice;
- otherwise the remembered choice is used (`./install.sh backend` shows it,
  `./install.sh backend set NAME` changes it; the file is
  `${XDG_CONFIG_HOME:-~/.config}/agent-workspace/backend`, mode 600);
- with neither, a terminal gets the annotated list and a question (the answer is
  remembered); without a terminal the same list is printed and the run exits
  non-zero.

The choice is also stored per container, so an existing container keeps the backend
it was created with.

| backend | what the workspace is | trade-off |
| --- | --- | --- |
| `kvm` (recommended when `/dev/kvm` exists) | a complete system: own kernel, init and modules, booted by libvirt/QEMU | kernel-dependent operations work; costs a bootable qcow2 and real memory/disk; needs libvirt + QEMU + a podman/docker helper |
| `podman` (recommended) | container in your rootless podman | lightest and fastest, no preparation; shares the host kernel |
| `docker` | container in your docker | same kernel-sharing trade-off; needs `--privileged --cgroupns=host` for an in-instance init |
| `incus` (not selectable in this version) | unprivileged Incus instance (daemon-owned) | kept visible, implemented and tested; *selecting* it is gated |

`kvm` is implemented: it boots the image's own rootfs and bootc kernel as a VM under
libvirt; see [docs/backend-model.md](backend-model.md#kvm-the-oci-image-as-a-bootable-vm)
for the build path, the captured boot and the host preparation. `incus` is the one
backend that is present but refused: `--backend incus` and
`./install.sh backend set incus` fail with an explanation, while `install.sh
backend`, `install.sh list` and `install.sh doctor` still list it.

| | podman / docker | incus | kvm |
| --- | --- | --- | --- |
| what the workspace is | container in your rootless podman / docker | unprivileged Incus instance (daemon-owned) | VM (libvirt/QEMU, own kernel) |
| agent home | named volume mounted at `/home/agent` | installer-managed host directory `~/.local/share/agent-workspace/incus/homes/<name>` mounted at `/home/agent` | inside the guest filesystem on the instance's qcow2 |
| agent working directory | `/home/agent` inside that volume | `/home/agent` inside the instance | `/home/agent` inside the guest |
| host workspace | none: no host path is mounted | none: no user host directory is attached | none: no host path is mounted |
| web UI | `--publish 127.0.0.1:<port>:3080` | `proxy` device on `127.0.0.1` | `hostfwd=tcp:127.0.0.1:<port>-:3080` |
| image | `pull` (and `commit` for a snapshot image) | `podman export` piped through `xz` into `incus image import`, cached by image ID | `podman create` + `export`, extracted into an ext4 disk and converted to qcow2 |
| fork / rollback | volume archives | `incus copy` plus home copies | qcow2 commit plus home archive over SSH |
| ready check | `<cli> --version` answers | `incus info` answers (the daemon is up) | `kvm_probe`: device, libvirt URI, tools, writable storage |
| exec / shell | engine `exec` | `incus exec` | SSH as the agent user on the per-instance loopback port |
| rescue | engine exec as root | `incus exec --user root` | serial console (`virsh console`, root autologin on ttyS0) |

The Incus daemon has to be initialised once by you, as root - `install.sh` never runs
`sudo`, never writes under `/etc` and never starts a daemon:

~~~bash
sudo systemctl enable --now incus.socket
sudo incus admin init --minimal
~~~

Until that is done the messages you can see are:

~~~text
backend incus is installed but not usable yet: <what incus said>
--backend/--engine incus was requested but incus is not installed
backend incus is not selectable in this version: ... (gate: installer/lib/engine.sh)
~~~

The first is "installed but not ready" (the error adds the two commands above); the
second is `--backend incus` on a host without the package; the third is the
selectability gate, which is what a user on this version sees.

**Verified against a real daemon:** nothing in CI, because the runner has no Incus -
`tests/incus.sh` drives a fake `incus` that logs its argv, and asserts the pipeline
(image import with `--alias`, disk devices, the proxy device, credentials over
stdin, exec/logs/commit/remove) verb by verb. Treat the Incus backend as
**experimental until the first report of a real create**: the verbs listed above are
asserted at the command level, not against `incusd`.

**KVM host preparation** is the same contract: the installer never runs `sudo`,
never writes under `/etc` and never starts a daemon, so the one-time setup is yours:

~~~bash
# Fedora
sudo dnf install libvirt virt-install qemu-img xorriso e2fsprogs podman
# Arch
sudo pacman -S libvirt virt-install xorriso e2fsprogs podman
sudo systemctl enable --now virtqemud.socket virtnetworkd.socket
~~~

The probe refuses with the first missing item, not a generic failure:

~~~text
backend kvm is installed but not usable yet: /dev/kvm is not present or not accessible
backend kvm is installed but not usable yet: qemu:///session is not reachable (start virtqemud.socket, or check your libvirt session)
backend kvm is installed but not usable yet: mkfs.ext4 is not on PATH
backend kvm is installed but not usable yet: /home/you/.local/share/agent-workspace/vms is not writable
~~~

KVM's build path and the captured boot transcript are in
[backend-model.md](backend-model.md#kvm-the-oci-image-as-a-bootable-vm).

**KVM:** proven end to end in the development distrobox, and partly asserted by
fakes in CI. The boot path itself was proven first: the image's rootfs and bootc
kernel booted under QEMU/KVM to a `fedora login:` prompt (`docs/backend-model.md`
has the command and excerpt). Later the backend itself ran the full path: `create`
built the disk from the OCI image, cloud-init created the `agent` user and installed
the per-instance SSH key, and the bounded poll reached SSH and the first-boot
marker; the web server started in the guest on port 3080 was fetched from the host
as `http://127.0.0.1:<forwarded port>/`; `backup` archived the home over SSH and the
archive listed it; `root`/`rescue` had the root autologin on the serial console
(`e2e login: root (automatic login)`); `remove` deleted the domain and the instance
directory. The evidence files are in `~/.local/share/aw-phasea/evidence/`
(`console-direct-boot.log`, `e2e-create.log`, `e2e-backup.log`). Every layer is also
asserted against fake `virsh`/`qemu-img`/`ssh` binaries by `tests/kvm.sh`, which
never needs `/dev/kvm`. Still unverified: `qemu:///system` (rootless
`qemu:///session` is the default and the proven path).

## Troubleshooting

### A KVM domain refuses to start: "UNIX socket path ... too long"

Symptoms: `install.sh create --backend kvm` writes the disk and the seed ISO, then
fails right after `virsh define` with

~~~text
error: Failed to start domain '<name>'
error: internal error: UNIX socket path '<XDG dir>/libvirt/qemu/lib/domain-N-<name>/monitor.sock' too long
~~~

and the serial console log is empty. Root cause: libvirt's QEMU session driver
builds the monitor/socket paths from `XDG_CONFIG_HOME`/`XDG_RUNTIME_DIR`, and the
filesystem `sun_path` limit is about 108 bytes; a deeply nested XDG directory can
exceed it even though the storage path is fine. Workaround: keep those two
directories short, which is their default on a normal login:

~~~bash
XDG_CONFIG_HOME="$HOME/.config" XDG_RUNTIME_DIR="/run/user/$(id -u)" ./install.sh create ...
~~~

`AW_KVM_ROOT` may stay deep: sockets are not placed under it. There is no
installer escape hatch; it honours the environment it is given. The error text
comes from libvirt's domain start, before QEMU runs.

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

### The published web port answers with a connection reset

Symptom: `curl -v http://127.0.0.1:3081/` (the port `install.sh list` reports) ends
in `Recv failure: Connection reset by peer`, while the container itself is up and
`podman ps` shows it running.

Root cause: the port is published by the engine even when nothing inside the
container is listening on it. The web UI is a process in the container, not a
service the image starts, so it is not running whenever the container was started
without it - the installer starts it, and a container started by hand (or one whose
first boot had not finished when it was created) has none.

Workaround: `./install.sh web <name>` starts it and prints the one-time sign-in link.
This is what `create`, `start`, `restart`, `recover`, `rollback`, `fork` and
`upgrade` do for you. When the first boot is still running the command says so
(`has not finished its first boot`) instead of printing a URL that does not answer;
wait for it and run the command again, or raise `CONTAINER_FIRSTBOOT_TIMEOUT`
(seconds, 180 by default) so `create` waits longer.

Escape hatch: `--no-web` on `create` (or a `WEB=0` line in the container's `meta`
under `~/.local/share/agent-workspace/containers/<name>/`) means no port is
published at all. An agent the installer has no web UI for is never given a
published port in the first place.

### A DSH plugin is missing inside the container

Symptom: the agent's UI or CLI is missing a plugin the image is supposed to ship,
and `/home/agent/.dsh/profiles/web` does not list it - or DSH logged
`skipping profile bundle "<name>"` while starting.

Root cause: the image ships its plugin set at
`/usr/share/agent-workspace/dsh/profiles/web`, and the first boot copies it into the
agent's home, which lives in the container's volume (see
[the default DSH plugin set](../README.md#the-default-dsh-plugin-set)). Three things
leave the volume without it:

- the profile directory exists but was created by DSH itself or edited by hand, so
  firstboot deliberately keeps it and warns
  (`kept the existing dsh profile web: this image did not create it`, or
  `kept the changed dsh profile web: it differs from plugin set <digest>`);
- the container predates the image that started shipping the set;
- the build turned the module off (`45-dsh-plugins=0`, or a `--build-arg
  IMAGE_MODULES=...` without it), in which case `/usr/share/agent-workspace/dsh`
  does not exist and firstboot logs `this image ships no dsh profiles`.

Where to look, in order:

~~~bash
./install.sh enter dsh-box ls /home/agent/.dsh/profiles/web
./install.sh enter dsh-box cat /home/agent/.dsh/profiles/web/.agent-workspace-profile
./install.sh enter dsh-box cat /usr/share/agent-workspace/dsh/profiles.version
~~~

The manifest records the plugin set the profile was seeded from; if it is missing, the
profile is not the image's (or a first boot older than that mechanism seeded it).

Workaround: remove the profile inside the container and let the next first boot seed it
- `./install.sh enter dsh-box rm -rf /home/agent/.dsh/profiles/web`, then
`./install.sh upgrade dsh-box` (or a `recover`, `fork` or a new `create` over the same
volume). Inside a running container, `dsh plugin --profile web add <package>` is DSH's
own supported way to add a plugin, but it needs network access and is not what the
image's default set goes through.

Escape hatch: to keep the image's set out of the way while you work on your own
profile, edit `/home/agent/.dsh/profiles/web/cordis.patch.yml` (firstboot never
writes it again) or disable individual plugins there; to keep it out of a build
entirely, set `45-dsh-plugins=0` in `config/modules.conf`.

### Locked out of the instance after `root ... off`

Symptom: after `./install.sh root dsh-box off`, logging in as `agent` inside the
instance is refused (`Authentication failure`, or `Account is locked`), and the
password file that used to exist under
`~/.config/agent-workspace/credentials/` is gone. `./install.sh enter dsh-box`
still works, because it runs as the container's default user (root), not as
`agent`.

Root cause: that is what `off` promises. It rotates the agent password to a new
random value that is written nowhere, then locks the account (`passwd -l`), so
nothing the agent could have read while root was on still authenticates. The old
password is not backed up; the host file is deleted as part of the same step.

Workaround, first choice: `rescue` opens a root shell inside the instance without
depending on the agent account, even when the configuration is broken enough that
`enter` cannot start the agent:

~~~bash
./install.sh rescue dsh-box              # starts it if stopped, then root shell
passwd agent                             # sets a new password and clears the lock
~~~

If there is no terminal (scripts, CI), use the non-interactive escape: copy the
data out first, then rebuild or repair at leisure.

~~~bash
./install.sh rescue dsh-box --copy data/   # copy one directory out to the current directory
~~~

`./install.sh enter dsh-box` is the lighter alternative when the container still
starts normally. Turning the switch back on (`./install.sh root dsh-box on`) also
restores a password login: it sets a fresh random password and writes it to the
host file again. If you want to keep a working login across `off`, copy the
password out of `~/.config/agent-workspace/credentials/<name>.root` first (mode
600, and the only copy).

Escape hatch: none is needed to reach the agent itself - `enter`, `shell` and
`rescue` run as root inside, and `sudo -u agent -i` gives you a shell as the
agent without any password.

### Disk full or a corrupted instance

Symptom: commands inside the instance fail with `No space left on device`,
`Read-only file system`, `failed to mount ...: Structure needs cleaning`, or the
container exits before systemd reaches a prompt and `./install.sh enter` reports
that the container did not stay up.

Root cause: the engine-managed volume or the instance disk filled up, or its
filesystem was damaged by a hard stop / host crash. The installer cannot repair
that in place, and it must not delete data to "fix" it.

Workaround, in this order - **take a backup before attempting any repair**:

~~~bash
./install.sh stop dsh-box
./install.sh backup dsh-box --to /safe/dsh-box-before-repair.tar.gz
./install.sh doctor dsh-box              # read-only diagnosis
~~~

`backup` verifies the archive it writes and refuses to overwrite; if the
filesystem is so damaged that the archive cannot be read, it deletes the partial
file and exits non-zero, which is the signal that the data is not salvageable this
way. Then create a fresh instance and restore into it, or use `rescue --copy` to
pull individual paths out before removing anything:

~~~bash
./install.sh restore dsh-box /safe/dsh-box-before-repair.tar.gz
./install.sh rescue dsh-box --copy data/      # per-path extraction, no restore
~~~

Escape hatch: never run `engine volume rm` on a volume that still holds data you
might want; copy it to another engine volume or a host directory you control
first. Archives and volume names are printed by the commands above, and backups
are plain `tar.gz` files you can inspect with `tar tzf` before trusting them.

### Distrobox and toolbox

The image is not a distrobox or toolbox image, and the project does not target
them: `install.sh` is the entry point and `tests/integration.sh` is the contract
for "the container runs". `distrobox create --image
ghcr.io/wraindrock/agent-workspace:latest --init` does start this image, but
`--init` boots systemd inside it, so it lands in the host inotify limit above
(the container exits 255 while the systemd boot fails).
