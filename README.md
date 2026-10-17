# agent-workspace

**Throwaway operating systems for coding agents.** `install.sh` asks a few questions
and creates containers on your Linux machine - each one a complete, pre-configured
Fedora bootc OS with the agent you chose inside it.

- **One entry point** - `./install.sh`, an interactive TUI. No manifest to write, no
  `docker run` incantation to memorise, no root required.
- **A whole OS per agent** - its own PID 1, systemd, users and package database
  (the host's SELinux policy still applies), so `dnf install`, `npm install -g` or
  a stray `rm -rf` stays inside.
- **Snapshots and rollback** - commit a container, roll back to it, recover it after an
  accident, or fork it into a second one: [docs/rollback.md](docs/rollback.md).
- **Declarative build** - the image is described by `image.env`, `config/modules.conf`
  and `config/agents.conf`; modules and agents have on/off switches, and the image
  records what it contains in its own manifest.
- **MIT licensed** - the build, the configuration and the installer are yours to fork.

~~~text
ghcr.io/wraindrock/agent-workspace:latest
~~~

## Quick start

~~~bash
curl -fsSL https://raw.githubusercontent.com/wraindrock/agent-workspace/main/install.sh -o install.sh
bash install.sh
~~~

That is the whole install. `install.sh` is one script: it fetches the libraries it needs
and checks each against a digest carried inside itself, so there is nothing to clone and
nothing left behind to keep in sync. The fetched files land in
`~/.cache/agent-workspace/bootstrap/`.

The TUI needs a terminal, so keep the script on disk for it. To drive subcommands instead,
pipe straight into bash - `-s --` passes the arguments through:

~~~bash
curl -fsSL https://raw.githubusercontent.com/wraindrock/agent-workspace/main/install.sh \
  | bash -s -- list
~~~

The TUI asks which agent goes into the container, what to call it, whether it should be
**persistent** (systemd, keeps its home volume across restarts) or **ephemeral** (run
once, then gone), and once for the credential that agent needs. Then it creates the
container and tells you how to enter it. All of the agent's data lives inside the
instance's own storage - the installer does not share a host directory into it.
That credential is written to a `0600` file under
`~/.config/agent-workspace/containers/` and passed to the container as an `--env-file`,
so it is never baked into the image; if you skip the question the container is still
created, and the installer says plainly that its agent has nothing to call a model with
until you add the key there.

Before anything is created the installer checks that the image is the one the registry
serves *now* - a local copy of a tag like `latest` can be days old, and a container
created from a stale one fails in ways that look like engine bugs. Digests and images you
built locally (`localhost/...`) have nothing to refresh from and are used as they are;
`--no-pull` keeps a local copy without asking the registry at all.

With no checkout on disk, run the subcommands through the same pipe:

~~~bash
iw() { curl -fsSL https://raw.githubusercontent.com/wraindrock/agent-workspace/main/install.sh | bash -s -- "$@"; }
iw list              # what this host already has
iw enter dsh-box     # run the agent inside its own OS
iw --help            # every subcommand, including non-interactive use
~~~

`main` is where reviewed work lands; `dev` receives it first. Both are served, and the
script verifies whichever you pick the same way:

~~~bash
curl -fsSL https://raw.githubusercontent.com/wraindrock/agent-workspace/dev/install.sh \
    | AW_INSTALL_REF=dev bash -s -- --help
~~~

Use the same ref for the script and for `AW_INSTALL_REF`. Each branch's `install.sh`
carries the digests of *its own* branch, so asking a `main` script to fetch `dev` files
makes it refuse them instead of silently mixing trees - that refusal is the check working,
and it is what stops a mirror from handing you different code than the script expects.

If you would rather read the code before running it, clone the repository instead: a
checkout is used as-is and needs no network at all.

~~~bash
git clone https://github.com/wraindrock/agent-workspace
cd agent-workspace
./install.sh
~~~

Nothing else in this repository is needed to *use* the project. The rest of this README
covers building your own image and what is inside it; the container reference is
[docs/containers.md](docs/containers.md).

### Without the installer

The same image is still a fine plain sandbox for a single throwaway run:

~~~bash
podman run --rm -it --workdir /root ghcr.io/wraindrock/agent-workspace:latest dsh
~~~

Run it rootless (`podman`, not `sudo podman`) so the throwaway container runs inside
your own user namespace. Nothing from this host is mounted into it; anything you want
to keep belongs in a named volume or must be copied out before the container exits.
The installer makes that durable for you: a named volume holds `/home/agent` - the
agent's working directory - and `backup`, `restore` and `rescue` move that data in and
out without ever exposing a host folder to the agent.

### On a bootc-capable machine (advanced, optional)

The image is a bootc image, so it can also become the OS of a machine you own:

~~~bash
sudo bootc switch --transport registry ghcr.io/wraindrock/agent-workspace:latest
sudo systemctl reboot
~~~

That is a different use case from the one this project is built around: the container
lifecycle commands below do not apply to a machine installed this way. Inside any
running instance the image's own CLI reports what it is:

~~~bash
agent-workspace version      # what this image is
agent-workspace manifest     # how it was built, module by module
agent-workspace doctor       # is the running system what the image promised?
~~~

The default image ships two harnesses, DSH and OpenCode:

~~~bash
# one agent, one OS, with its data inside the container
podman run --rm -it --workdir /root ghcr.io/wraindrock/agent-workspace:latest dsh

# the other bundled harness
podman run --rm -it --workdir /root ghcr.io/wraindrock/agent-workspace:latest opencode

# systemd is PID 1, so a detached container can be entered like a machine;
# the named volume survives the container and holds everything in /home/agent
podman run -d --name agent-box --volume agent-box-home:/home/agent --systemd=always \
  ghcr.io/wraindrock/agent-workspace:latest
podman exec -it agent-box /bin/bash
~~~

On first boot inside any instance, the image creates the `agent` user that owns the
agent workspace and that the web UI runs as (see [First boot](#first-boot)). A run
started this way does not start the web UI itself; the installer does that for the
containers it creates, and `./install.sh web` does it for any other one.

## What "declarative" means here

Three files describe everything, and the image proves that it matches them:

| File | Declares |
| --- | --- |
| `image.env` | image identity: name, organisation, description, default tag, base image, agent user |
| `config/modules.conf` | which build modules run (`20-container-tools=1`, `40-agent-harnesses=1`, ...) |
| `config/agents.conf` | which agent harnesses are installed (`dsh=1`, `opencode=1`, ...) |

At build time the pipeline writes `/usr/share/agent-workspace/manifest.json` **inside
the image**, containing the modules that ran, the agents that were installed, the
toolchain versions and the exact base image. On a deployed host:

~~~bash
agent-workspace manifest | jq '.modules, .agents, .baseImage'
~~~

`agent-workspace doctor --strict` exits non-zero when a machine disagrees with its
own manifest - that is what you run in a test. The daily health timer instead runs
`agent-workspace doctor --quiet` and only logs the result.

## Modules

Modules run in filename order. Each directory in `build_files/modules/` contains a
`module.env` (name, description, default state) and an `install.sh`.

| Module | What it adds |
| --- | --- |
| `00-preflight` | validates the build environment, records the base image and Fedora release |
| `10-base-packages` | git, git-lfs, curl, jq, rsync, ssh client, archive and network basics |
| `20-container-tools` | podman, buildah, skopeo, crun, netavark, passt, `podman.socket`, sub-id ranges |
| `30-agent-toolchains` | gcc/make, gh, just, Node.js + pnpm/tsx/typescript, Python + pipx, uv |
| `40-agent-harnesses` | the agent CLIs selected in `config/agents.conf` |
| `45-dsh-plugins` | the default DSH plugin set, installed from a committed lockfile so a container needs no network to load it |
| `50-devtools` | neovim, ripgrep, tmux, tree, zsh, ShellCheck, direnv, fd-find, git-delta, htop, make (optional bat, btop, eza, starship) |
| `60-system-config` | systemd units, registries config, profile.d, `/etc/skel` |
| `80-manifest` | writes the image manifest and module list |
| `90-cleanup` | drops caches and logs so the image stays lean |

See [docs/modules.md](docs/modules.md) for the module contract and how to add one.

## Agents

`config/agents.conf` selects which harnesses ship in the image. Recipes live in
`build_files/modules/40-agent-harnesses/agents/`.

| Agent | Recipe | Installed via |
| --- | --- | --- |
| DSH (DeepSeek Harness) | `dsh.sh` | npm `@deepseek-ai/dsh` |
| OpenCode | `opencode.sh` | npm `opencode-ai` |
| Claude Code | `claude-code.sh` | npm `@anthropic-ai/claude-code` |
| Codex CLI | `codex.sh` | npm `@openai/codex` |
| Gemini CLI | `gemini-cli.sh` | npm `@google/gemini-cli` |
| Aider | `aider.sh` | pipx `aider-chat` |

The default image ships DSH and OpenCode; the other recipes are one flip in
`config/agents.conf` away. Each recipe declares the command it installs and the
credentials it reads, and the built image publishes that as `agentCatalog` in its
manifest. The installer's menu starts from the built-in `dsh` and `opencode`
entries and merges the image's `agentCatalog` over them, so it follows the build
while still offering the built-ins when the manifest cannot be read.

Adding your own is a small shell function - see [docs/agents.md](docs/agents.md).

### The default DSH plugin set

The image carries this project's default DSH plugins - the set the maintainers run -
as a finished profile under `/usr/share/agent-workspace/dsh/profiles/web`: the plugin
list, the workspace settings, the lockfile and a `node_modules` installed at build
time. The plugins are named in
[`system_files/usr/share/agent-workspace/dsh/profiles/web/package.json`](system_files/usr/share/agent-workspace/dsh/profiles/web/package.json),
and what ships is exactly what the committed `pnpm-lock.yaml` resolves to.

DSH reads profiles from the agent's own `$HOME/.dsh`, which lives in the container's
workspace volume, so the first boot seeds the image's copy into
`/home/agent/.dsh/profiles/web` - before the completion marker, so the web UI cannot
start against a home that has no profile. Because this runs again for every new
container over the same volume, the rules are deliberately narrow:

- a missing profile is seeded; a profile already at the image's plugin set is left
  completely alone;
- a profile at an older set is refreshed, and the dependency list, the lockfile and
  `node_modules` are replaced together;
- `cordis.patch.yml` is yours: it is written once, on the first seed, and never
  touched again. Preferences belong there, not in `package.json`;
- a profile whose files you edited is kept, with a warning naming the directory and
  the plugin set it differs from. To take the image's set instead, remove
  `/home/agent/.dsh/profiles/web` inside the container and let the next first boot
  seed it (`./install.sh upgrade dsh-box`, or a `recover`, `fork` or new `create`).

A build that wants no plugin set at all turns the module off - `45-dsh-plugins=0` in
`config/modules.conf`, or leave it out of `--build-arg IMAGE_MODULES=...`.

The plugins are third-party npm packages: their lifecycle scripts run as root in the
image build, and their code runs inside the agent's container afterwards. See
[SECURITY.md](SECURITY.md). To check what a running container actually has:

~~~bash
./install.sh enter dsh-box ls /home/agent/.dsh/profiles/web
./install.sh enter dsh-box cat /home/agent/.dsh/profiles/web/.agent-workspace-profile
~~~

The second file records the plugin set the profile was seeded from, and the digest of
every file the image owns in it.

## Managing containers

The installer is the interface - interactive, or one subcommand per action:

~~~bash
./install.sh create --agent dsh --name dsh-box
./install.sh list
./install.sh snapshot dsh-box --label before-refactor
./install.sh rollback dsh-box
./install.sh fork dsh-box dsh-experiment
./install.sh doctor --strict
~~~

A whole set can be declared in a file and created non-interactively:

~~~
# name       agent     lifecycle
review-box   dsh       persistent
scratch      opencode  ephemeral
~~~

~~~bash
./install.sh create --file containers.conf --dry-run   # show the engine commands only
./install.sh create --file containers.conf --save saved.conf
~~~

`persistent` containers run systemd, keep `/home/agent` in a named volume and survive
reboots; `ephemeral` ones run one command and are removed on exit. The agent menu
starts from the built-in `dsh`/`opencode` entries and merges the image's
`agentCatalog` over them, so it follows the build while still offering the built-ins
when the manifest cannot be read. Full reference:
[docs/containers.md](docs/containers.md).

## Where the data lives: backup, restore and rescue

A persistent instance keeps the agent's whole working tree under `/home/agent`,
inside engine-managed storage: a named volume for `podman`/`docker`, the
instance's own disk plus an installer-managed home directory for `incus`, and the
instance's qcow2 for `kvm`. No host
directory is bind-mounted into the instance any more, so creating or entering a
container never makes a folder on this host the agent's working directory. The
installer's own state - credentials, the backend choice, metadata and snapshots -
still lives on the host under `~/.config` and `~/.local/share`.

Moving data in and out is explicit and verified:

~~~bash
./install.sh backup dsh-box                         # ./agent-workspace-backup-<name>-<UTC>.tar.gz
./install.sh backup dsh-box --to /safe/dsh-box.tar.gz
./install.sh restore dsh-box /safe/dsh-box.tar.gz   # refuses a running instance
./install.sh rescue dsh-box                         # interactive root shell inside the instance
./install.sh rescue dsh-box --copy notes.txt        # copy a path out to the current directory
~~~

`backup` archives `/home/agent` plus a root `manifest.txt` (instance, agent, mode,
engine, image and digest, creation time, data markers). It refuses to overwrite an
existing file, verifies the archive after writing (`manifest.txt` and the home data
must be listable) and deletes a partial archive instead of leaving a green-looking
failure; it prints the path and member count. `--dry-run` prints the plan and writes
nothing.

`restore` validates the source archive before touching anything, refuses to restore
into a running instance (stop it first), and takes a safety snapshot of the current
home volume named `<volume>-pre-restore-<UTC timestamp>` unless you pass
`--skip-safety`. It prints how many entries the snapshot holds, restores the archive,
then verifies the volume before reporting what it put back. `--dry-run` changes
nothing.

`rescue` is the way back in when the instance is stopped or its configuration is
broken: it starts a stopped instance, then either opens an interactive root shell
inside it (a terminal is required) or copies one file/directory out with
`--copy PATH`. Run `./install.sh rescue NAME --copy data/` from the host directory
where you want the copy to land; it prints the resulting host path. This is also the
escape hatch when `./install.sh root NAME off` locked the agent account.

## Root inside the instance

The agent user has no `sudo` rights by default. Whether it may become root inside an
instance is a live switch you control, not something fixed when the container is
created:

~~~bash
./install.sh root dsh-box status   # default. Verified live, not by reading files
./install.sh root dsh-box on       # /etc/sudoers.d/agent-workspace, NOPASSWD, mode 0440
./install.sh root dsh-box off      # remove it, rotate the password, lock the account
~~~

`on` takes effect immediately: `sudo` re-reads `sudoers.d` on every call, so the
agent's next `sudo` works with no restart and no re-login. The rule is for the agent
user only, and it is validated with `visudo -cf` on a temporary file before it
becomes live - a broken sudoers file is never installed. Both directions are
idempotent: repeating the word you already have re-verifies and changes nothing.
`status` runs `sudo -n true` as the agent and separately reports whether the rule
file is present, so the file and what sudo actually grants are never confused. A
stopped instance cannot answer, and says so instead of guessing.

`on` also gives the agent account a fresh random password and keeps it on the host
at `~/.config/agent-workspace/credentials/<name>.root` with mode `600`, next to the
container credentials - the only thing the host stores for this switch, and the one
value that lets you log in as the agent inside the instance. It is never printed;
only the path is. `off` removes the rule, rotates that password to a value nothing
keeps, locks the account and deletes the host file, then verifies that
`sudo -n true` now fails.

`off` does **not** revoke what is already running: a process the agent started as
root keeps that privilege until it exits. And root inside the instance is the same
trust domain as the agent itself - it is container root, never host root;
[SECURITY.md](SECURITY.md) spells that boundary out.

## Opening the agent's web UI

DeepSeek Harness ships a web UI. The container keeps it on its own loopback and the
installer publishes it on yours - and starts it, as soon as the container's first
boot has created the `agent` user it runs as. Every command that leaves a container
running does the same: `create`, `start`, `restart`, `recover`, `rollback`, `fork`
and `upgrade`. When the UI comes up you get a one-time link:

~~~
✓ dsh web UI is published on http://127.0.0.1:34700/ (container port 3080)
  open: http://127.0.0.1:34700/?token=...
~~~

That first request sets a 30-day cookie in your browser, so the token is only needed
once. If the UI is not running - a container that was stopped outside the installer,
or one whose first boot was still going when it was created - this prints the same
link, and fails loudly instead of handing you a URL that answers with a connection
reset:

~~~bash
./install.sh web dsh-box
~~~

The host port is chosen when the container is created and remembered with it, so
`rollback`, `recover` and `upgrade` keep the same URL; `fork` assigns a fresh one.
`./install.sh create --web-port 8080` picks a port yourself and `--no-web` skips the
published port entirely. An agent this installer has no web UI for (`opencode`)
publishes no port at all: a published port with nothing behind it only looks like a
broken install. The mapping is always `127.0.0.1:<host port>:3080` - nothing is
reachable from the network. Details: [docs/containers.md](docs/containers.md).

## Snapshots, rollback and forks

The unit of rollback is the container, not your host system:

~~~bash
./install.sh snapshot dsh-box              # commit the filesystem, archive /home/agent
./install.sh rollback dsh-box              # back to the latest snapshot (or --to ID)
./install.sh recover dsh-box               # restart, restore or rebuild a lost container
./install.sh fork dsh-box dsh-experiment   # branch a second container off the first
./install.sh upgrade dsh-box --image ghcr.io/wraindrock/agent-workspace:latest
~~~

`upgrade` takes a `pre-upgrade` snapshot first, so a bad image is one `rollback` away;
`fork` snapshots its source first for the same reason, unless you pass `--live`.
Retention, exact semantics and what is *not* covered:
[docs/rollback.md](docs/rollback.md).

## Verifying the image

Images are signed with [cosign](https://docs.sigstore.dev/). Releases are signed
keylessly through GitHub's OIDC identity by default:

~~~bash
cosign verify \
  --certificate-identity-regexp '^https://github.com/wraindrock/agent-workspace/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/wraindrock/agent-workspace:latest
~~~

If you prefer a pinned public key, run `just cosign-keygen`, store the private key
as the `SIGNING_SECRET` repository secret, and the workflow switches to key-based
signing automatically.

## Building it yourself

~~~bash
git clone https://github.com/wraindrock/agent-workspace
cd agent-workspace
just check     # repository lint, no podman required
just build     # build the image with podman
just verify    # build + every container-level test
just verify-all # the above plus the engine-free contract tests
~~~

Requirements: one backend - `kvm` (recommended when `/dev/kvm` exists; needs
libvirt + QEMU + `podman`/`docker`), `podman`, `docker` or `incus` (see
[Backends](#backends)) - plus `bash` 4.4+ for
`install.sh`. Building and linting additionally want `just`; the lint uses
`shellcheck`, `actionlint` and `python3` + `pyyaml` when they are present and skips them when they are not; `tests/smoke.sh`
separately needs `jq`. CI installs `actionlint` and `just` explicitly, and relies on
the runner image for `shellcheck`, `jq` and `python3`. Every pull request runs the
same twelve test scripts - `tests/lint.sh`, `tests/install.sh`, `tests/smoke.sh`,
`tests/integration.sh`, `tests/portability.sh`, `tests/decoupling.sh`,
`tests/contract.sh`, `tests/firstboot.sh`, `tests/bootstrap.sh`, `tests/i18n.sh`,
`tests/incus.sh` and `tests/kvm.sh`. `tests/integration.sh` creates a real
container through `install.sh`, and `tests/portability.sh` proves the image boots
on a host whose kernel settings were never tuned; both need a host where rootless
podman can boot systemd (see
[docs/containers.md](docs/containers.md#troubleshooting)). The other four are
static or CLI-level, so they need no engine, no root and no network - the suite is
not "only tested on my machine".

## Repository layout

~~~text
install.sh               the one entry point: TUI for creating agent containers
installer/lib/           engine.sh, state.sh, ui.sh, agents.sh, commands.sh
image.env                image identity and build parameters
Containerfile            the build contract: context stage + image stage
Justfile                 local build, image check and release helpers
build_files/
  build.sh               the module pipeline
  lib/common.sh          shared build helpers
  modules/<NN-name>/      one module per concern, each with module.env + install.sh
config/                  modules.conf, agents.conf - the declarative switches
system_files/            verbatim overlay copied to / (systemd, profile.d, registries)
runtime/                 the in-image CLI (version, manifest, modules, agents, status, doctor)
tests/                   lint, install, smoke, integration, portability,
                         decoupling, contract, firstboot + a fake engine fixture
docs/                    architecture, modules, agents, containers, rollback
~~~

Full design notes: [docs/architecture.md](docs/architecture.md).

## First boot

A one-shot `agent-workspace-firstboot.service` creates the `agent` user
(configurable via `AGENT_WORKSPACE_USER`, set per machine in
`/etc/agent-workspace/config.env`), adds it to `wheel`, grants it a sub-id range so
rootless podman works, and enables lingering. That user owns the agent workspace and
is the user the web UI runs as; the terminal side (`install.sh enter`, `install.sh
shell`) execs the agent CLI as the container's own root user, so the container is not
a security boundary against the agent. A daily
`agent-workspace-health.timer` runs `agent-workspace doctor --quiet` so drift
shows up in `journalctl` instead of in a broken agent session.

The same service seeds the image's default DSH plugin set into the agent's home (see
[The default DSH plugin set](#the-default-dsh-plugin-set)), and it writes its
completion marker last: whatever fails earlier is reported and then left behind, so
that a half-provisioned container is never mistaken for a finished one.

## Interface language

`install.sh` speaks the language of the host locale, resolved in this order: `LC_ALL`,
`LC_MESSAGES`, `LANG`. English and Simplified Chinese (`zh`) are translated today; every other
locale falls back to English as a whole rather than showing a half-translated mix. Set
`AW_LANG_OVERRIDE=en` (or `zh`) to pick one explicitly.

What is translated is everything the installer says to you: the TUI, prompts, section headings,
table headers, `--help`, `doctor`, and every error and confirmation. `tests/i18n.sh` asserts that
no message bypasses the catalogue, that no key is defined twice, and that the command and flag
column of `--help` is byte-identical in both languages, so a translation cannot quietly rename a
flag.

Four things stay English on purpose - the boundary rather than an oversight: the "needs bash 4.4"
guard and the bootstrap's "fetched N files" line, which are printed before the catalogue has been
fetched; the `CONTAINER=`/`NAME` declaration-file format, which is machine-readable; and the
`dry-run` label with the engine command it prints, which is a shell command you may copy verbatim.

## Backends

`install.sh` does not talk to an engine directly: it calls a small set of verbs
(create, exec, logs, copy, remove, ...) and a backend implements them. **There is
no `auto`**: probing the host and silently picking one hides a trade-off only you
can weigh, so `install.sh` never decides for you.

- `--backend NAME` (`--engine` is an accepted alias) picks one for that run and is
  never written back over your remembered choice;
- with no `--backend`, a remembered choice is used; with none recorded and a
  terminal, the list below is printed and you pick (the answer is remembered);
- without a terminal and without a recorded choice, the same list is printed and
  the run **fails** with a non-zero status instead of guessing.

`./install.sh backend` shows the remembered choice and `./install.sh backend set
NAME` changes it (stored at `${XDG_CONFIG_HOME:-~/.config}/agent-workspace/backend`,
mode 600). The backend is also recorded per container, so an existing container
keeps the backend it was created with; `install.sh doctor` shows both.

| backend | what the workspace is | trade-off |
| --- | --- | --- |
| `kvm` **recommended** | a complete system: its own kernel, init and modules, booted by libvirt/QEMU | operations that need a kernel work; costs building the image into a bootable qcow2 and giving up real memory and disk |
| `podman` **recommended** | a rootless container in your podman | lightest and fastest, no preparation; shares the host kernel, so some operations are structurally impossible |
| `docker` alternative | a container in your docker | same kernel-sharing trade-off; needs `--privileged --cgroupns=host` for an in-instance init (the installer adds them); useful where docker is already your tool |
| `incus` *not selectable in this version* | an unprivileged Incus *instance* | kept visible and implemented; selecting it is refused on this host system for now |

The list is annotated with what the host actually has: a backend that is not
installed is marked `not installed`, `kvm` additionally reports the first missing
item (device, libvirt URI, tool or storage) and the package command that would fix
it, and `incus` is marked `not selectable in this version`.

### Incus is visible, not hidden

`installer/lib/backend-incus.sh` stays in the tree, stays in the backend list and
stays under test; only *selecting* it is gated. `--backend incus` and
`./install.sh backend set incus` fail with a message saying this host system cannot
enable it yet, and how it is turned back on (a different host system; the gate is
one variable in `installer/lib/engine.sh`).

The Incus backend is the only one that needs a host-level step first, and it is the
one step `install.sh` will not take for you (`incus` has to be installed, its daemon
running and its storage/bridge initialised - that is a host decision, not an
installer side effect):

~~~bash
sudo systemctl enable --now incus.socket   # or: sudo systemctl enable --now incus
sudo incus admin init --minimal            # default storage pool + incusbr0 bridge
~~~

`install.sh` never runs `sudo`, never writes under `/etc` and never starts a daemon.

An Incus workspace differs from a container in three ways worth knowing:

- the agent's home is an installer-managed **directory on this host** -
  `~/.local/share/agent-workspace/incus/homes/<name>` - not a named volume, mounted
  with `shift=true` so the agent user owns it inside the instance. It is the one
  host-visible piece of instance data (the installer owns and validates it; it is
  not a user-selected workspace folder). `backup`, `fork` and `rollback` copy files;
  there is no `podman commit` involved;
- the web UI is published by a `proxy` device bound to `127.0.0.1`, so the port stays
  loopback-only the same way it does with `--publish 127.0.0.1:...`;
- the workspace is an **unprivileged instance**: its root is a sub-uid/sub-gid
  mapping of your user rather than host root, and like every other backend here it
  shares your kernel and is **not** a virtual machine.

The OCI image never reaches the daemon as an image reference: the backend exports it
with `podman` (or `docker`, whichever is present), pipes the rootfs through
`xz` and `incus image import`, and caches the result under the image ID, so a moving
tag re-imports only when its digest actually changed. `docs/containers.md` has the
per-backend details and what is still unverified.

### KVM: a VM made from the same image

`--backend kvm` boots the image's own rootfs under KVM instead of running it as a
container. It is the recommendation when `/dev/kvm` exists, and it needs one
one-time host preparation the installer never performs for you (the probe names
exactly what is missing and prints the package command):

~~~bash
# Fedora: sudo dnf install libvirt virt-install qemu-img xorriso e2fsprogs podman
# Arch:   sudo pacman -S libvirt virt-install xorriso e2fsprogs podman
sudo systemctl enable --now virtqemud.socket virtnetworkd.socket
~~~

It drives `qemu:///session` by default - rootless, user-mode networking, no system
service - and stores instances under
`${XDG_DATA_HOME:-~/.local/share}/agent-workspace/vms`. `AW_KVM_URI` and
`AW_KVM_ROOT` override the URI and the storage root; `qemu:///system` is opt-in,
never automatic.

The build path is the one Phase A proved and the backend implements: export the OCI
rootfs, use the image's own bootc kernel and initramfs, build a rootless ext4 image
inside an unprivileged user namespace (`unshare -r`, so root-only modes and ownership
are recorded without host root), convert it to qcow2, and
boot it direct-kernel (`root=/dev/vda rw console=ttyS0`). A NoCloud cloud-init seed
ISO creates the `agent` user and installs a per-instance SSH key, so `enter`,
`backup` and `restore` are plain SSH streams. The serial console is the rescue path
(`root`/`rescue`), and `logs` tails it. Guest port 3080 is published as
`hostfwd=tcp:127.0.0.1:<port>-:3080`, so a URL requested inside the VM is reachable
on the host loopback - the same presentation rule as the other backends, with no
data copied out. `ephemeral` mode is deliberately refused for VMs. The full design,
the captured console excerpt and the exact `virt-install` command are in
[docs/backend-model.md](docs/backend-model.md#kvm-the-oci-image-as-a-bootable-vm).

## Notes and limitations

- GHCR creates a new package **private**. This project's package is public, so
  anonymous `podman pull` and `bootc switch` work; if you publish your own fork,
  flip *Packages -> agent-workspace -> Package settings -> Change visibility*.
- The default base is `ghcr.io/ublue-os/base-main:latest` (Fedora + bootc, no
  desktop). Desktop users can switch `BASE_IMAGE` to `ghcr.io/ublue-os/bluefin:stable`
  or `ghcr.io/ublue-os/aurora:stable`; minimalists can use
  `quay.io/fedora/fedora-bootc:44`.
- Containers are isolated from each other and from your host, but they share the
  host kernel. They are not virtual machines.
- The agent inside a container runs with your user's privileges on this host through
  rootless podman or docker; that is the whole point, and it is also the boundary.
- `docker` needs `--privileged --cgroupns=host` for the image's systemd to be PID 1.
  The installer adds those flags for you; prefer `podman` when you have the choice.
- The `incus` backend is visible but not selectable in this version, and needs the
  one-time host step in [Backends](#backends) before it can be used. Its instance
  is unprivileged, so the container's root is a sub-uid of yours rather than host root.
- The `kvm` backend is a real VM with its own kernel: root inside is guest root, not
  host root, and the boundary is the hypervisor rather than a shared kernel. It needs
  `/dev/kvm`, libvirt and a `podman`/`docker` helper to export the image, and it uses
  more memory and disk than a container. It refuses `ephemeral` mode.
- Booting systemd in a container needs host kernel headroom. The kernel charges
  inotify instances per *user* (`fs.inotify.max_user_instances`, 128 by default),
  a desktop session spends most of that budget, and once it is gone the container
  exits with `Failed to allocate manager object: Too many open files`. Raise the
  limit - [docs/containers.md](docs/containers.md#troubleshooting) has the exact
  commands and how to tell this apart from a container that dies for another reason.
- Distrobox and toolbox are not targets: `install.sh` is the entry point, and
  `tests/integration.sh` is the contract for "the container runs". The same
  troubleshooting section says what `distrobox create --init` runs into.

## Contributing

Issues and pull requests are welcome - see [CONTRIBUTING.md](CONTRIBUTING.md) and
[SECURITY.md](SECURITY.md). This project follows the
[Contributor Covenant](CODE_OF_CONDUCT.md).

## License

[MIT](LICENSE) (c) 2026 Wraindrock.

agent-workspace builds on the work of the Fedora bootc and
[Universal Blue](https://universal-blue.org/) communities; it is an independent
project and is not affiliated with either.
