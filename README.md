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
once, then gone), which host directory to mount at `/workspace`, and once for the
credential that agent needs. Then it creates the container and tells you how to enter it.
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
podman run --rm -it -v "$PWD:/workspace:z" --workdir /workspace \
  ghcr.io/wraindrock/agent-workspace:latest dsh
~~~

Run it rootless (`podman`, not `sudo podman`) so everything the agent writes into
`/workspace` belongs to your user. The installer does that for you: a named volume
holds `/home/agent` and your chosen host directory is mounted at `/workspace`.

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
# one agent, one OS, your code mounted at /workspace
podman run --rm -it -v "$PWD:/workspace:z" --workdir /workspace \
  ghcr.io/wraindrock/agent-workspace:latest dsh

# the other bundled harness
podman run --rm -it -v "$PWD:/workspace:z" --workdir /workspace \
  ghcr.io/wraindrock/agent-workspace:latest opencode

# systemd is PID 1, so a detached container can be entered like a machine
podman run -d --name agent-box -v "$PWD:/workspace:z" --systemd=always \
  ghcr.io/wraindrock/agent-workspace:latest
podman exec -it agent-box /bin/bash
~~~

On first boot inside any instance, the image creates the `agent` user that owns the
agent workspace and runs the web UI (see [First boot](#first-boot)).

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

## Managing containers

The installer is the interface - interactive, or one subcommand per action:

~~~bash
./install.sh create --agent dsh --name dsh-box --workspace "$PWD"
./install.sh list
./install.sh snapshot dsh-box --label before-refactor
./install.sh rollback dsh-box
./install.sh fork dsh-box dsh-experiment
./install.sh doctor --strict
~~~

A whole set can be declared in a file and created non-interactively:

~~~
# name       agent     lifecycle   workspace
review-box   dsh       persistent  ~/work/review
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

## Opening the agent's web UI

DeepSeek Harness ships a web UI. The container keeps it on its own loopback and the
installer publishes it on yours:

~~~bash
./install.sh web dsh-box
~~~

The command starts `dsh web` inside the container, waits for it to answer, and prints
a one-time link:

~~~
✓ dsh web UI is published on http://127.0.0.1:34700/ (container port 3080)
  open: http://127.0.0.1:34700/?token=...
~~~

That first request sets a 30-day cookie in your browser, so the token is only needed
once. The host port is chosen when the container is created and remembered with it, so
`rollback`, `recover` and `upgrade` keep the same URL; `fork` assigns a fresh one.
`./install.sh create --web-port 8080` picks a port yourself and `--no-web` skips the
published port entirely. The mapping is always `127.0.0.1:<host port>:3080` - nothing
is reachable from the network. Details: [docs/containers.md](docs/containers.md).

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

Requirements: `podman` (or `docker`) and `just`, plus `bash` 4.4+ for `install.sh`.
The lint uses `shellcheck`, `actionlint`, `just` and `python3` + `pyyaml` when they
are present and skips them when they are not; `tests/smoke.sh` separately needs `jq`.
CI installs `actionlint` and `just` explicitly, and relies on the runner image for
`shellcheck`, `jq` and `python3`. Every pull request runs the same eight test
scripts - `tests/lint.sh`, `tests/install.sh`, `tests/smoke.sh`,
`tests/integration.sh`, `tests/portability.sh`, `tests/decoupling.sh`,
`tests/contract.sh` and `tests/firstboot.sh`. `tests/integration.sh` creates a real
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
runs the web UI; the terminal side (`install.sh enter`, `install.sh shell`) execs the
agent CLI as the container's own root user, so the container is not a security
boundary against the agent. A daily
`agent-workspace-health.timer` runs `agent-workspace doctor --quiet` so drift
shows up in `journalctl` instead of in a broken agent session.

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
