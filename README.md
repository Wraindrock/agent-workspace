# agent-workspace

A **declarative, rollback-capable Fedora bootc system container** for running coding
agents and general-purpose agents. One image describes its whole build, allows every
part to be switched off, and can be atomically rolled back on any host.

- **bootc / OCI native** - the OS *is* an image. `bootc switch` to move forward,
  `bootc rollback` to go back, no reinstall and no package drift.
- **Declarative** - modules and agents are declared in `config/`, parameters in
  `image.env`. The build reads those files; you never hand-edit a live machine.
- **Modular** - nine ordered build modules, each with an on/off switch, each
  recorded in the image's own manifest.
- **Batteries included** - podman, git, node, python, the usual shell tooling and
  a set of agent harnesses, pre-configured and ready to run rootless.
- **MIT licensed** - the build, the configuration and the CLI are yours to fork.

~~~text
ghcr.io/wraindrock/agent-workspace:latest
~~~

## Quick start

### On a bootc-capable machine (recommended)

~~~bash
sudo bootc switch --transport registry ghcr.io/wraindrock/agent-workspace:latest
sudo systemctl reboot
~~~

After the reboot, `agent-workspace` is on `PATH`:

~~~bash
agent-workspace version      # what this image is
agent-workspace manifest     # how it was built, module by module
agent-workspace doctor       # is the running system what the image promised?
agent-workspace rollback     # undo, atomically, whenever you want
~~~

### As an isolated agent sandbox

This is a **complete operating system**, not a slim app image: Fedora bootc with
its own PID 1, systemd, users, package database and SELinux policy. Run it under
podman and every agent gets a whole OS of its own - an `npm install -g`, a
`dnf install`, a stray `rm -rf` or a broken config stays inside that container:

~~~bash
# one agent, one OS, your code mounted at /workspace
podman run --rm -it \
  -v "$PWD:/workspace:z" --workdir /workspace \
  ghcr.io/wraindrock/agent-workspace:latest dsh

# the default image ships two harnesses; the other one is opencode
podman run --rm -it -v "$PWD:/workspace:z" --workdir /workspace \
  ghcr.io/wraindrock/agent-workspace:latest opencode

# drop the mount and the agent gets a fully disposable filesystem
podman run --rm -it --entrypoint /bin/bash \
  ghcr.io/wraindrock/agent-workspace:latest
~~~

Run **rootless** (`podman`, not `sudo podman`): container root is then your own
user on the host, so everything the agent writes into `/workspace` belongs to
you. On a booted system the image additionally creates the unprivileged `agent`
user on first boot.

From a clone of this repository the same command is one recipe:

~~~bash
just build                # build the image locally
just sandbox              # run dsh against $PWD, in a throwaway OS
just sandbox opencode     # the other bundled harness
just sandbox /bin/bash    # just a shell inside the sandbox
~~~

Want systemd and the full OS running in the sandbox? Leave the default entrypoint
and exec into it:

~~~bash
podman run -d --name agent-box -v "$PWD:/workspace:z" \
  ghcr.io/wraindrock/agent-workspace:latest
podman exec -it agent-box /bin/bash
~~~

Lifecycle commands (`switch`, `rollback`, `update`, `pin`) detect that they are
inside a container and refuse politely instead of half-working.

### Install from an ISO or VM image

Download a qcow2 or Anaconda ISO from the latest
[build-disk workflow](https://github.com/wraindrock/agent-workspace/actions/workflows/build-disk.yml)
run, boot it, and the installer lays down the same image. Build your own with:

~~~bash
just build-qcow2   # ./output/*.qcow2
just build-iso     # ./output/*.iso
just run-vm        # boot the qcow2 in qemu
~~~

## What "declarative" means here

Three files describe everything, and the image proves that it matches them:

| File | Declares |
| --- | --- |
| `image.env` | image identity: name, organisation, description, default tag, base image, agent user |
| `config/modules.conf` | which build modules run (`20-container-tools=1`, `40-agent-harnesses=0`, ...) |
| `config/agents.conf` | which agent harnesses are installed (`dsh=1`, `opencode=1`, ...) |

At build time the pipeline writes `/usr/share/agent-workspace/manifest.json` **inside
the image**, containing the modules that ran, the agents that were installed, the
toolchain versions and the exact base image. On a deployed host:

~~~bash
agent-workspace manifest | jq '.modules, .agents, .baseImage'
~~~

If a machine disagrees with its own manifest, `agent-workspace doctor --strict`
exits non-zero - which is exactly what the daily health timer runs.

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
| `50-devtools` | neovim, ripgrep, tmux, fzf-adjacent shell tooling, shellcheck, direnv |
| `60-system-config` | systemd units, sysctl tuning, registries config, `/etc/skel` |
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
manifest, so tooling offers exactly the agents a build contains.

Adding your own is a small shell function - see [docs/agents.md](docs/agents.md).

## Containers on your host

`install.sh` in the repository root turns the image into real containers: it
creates as many as you want, asks which agent each one runs, and keeps every
credential in its own file.

~~~bash
./install.sh                              # wizard: how many, named what, which agent
./install.sh --list                       # what this host already has
./install.sh --file containers.conf --dry-run
~~~

The same thing can be written down:

~~~
# name       agent     lifecycle   workspace
review-box   dsh       persistent  ~/work/review
scratch      opencode  ephemeral
~~~

`persistent` containers run systemd, keep `/home/agent` in a named volume and
survive reboots (`podman exec -it review-box bash -lc dsh` to step in);
`ephemeral` ones run a single command and are removed on exit. The agent menu is
read from the image manifest, so it always matches the build. Full reference:
[docs/containers.md](docs/containers.md).

## Rollback, switching and pinning

Every change to this image is a new deployment, and every deployment keeps its
predecessor:

~~~bash
agent-workspace update            # stage the newest build of your tag
sudo systemctl reboot            # boot it
agent-workspace rollback         # back to the previous deployment
agent-workspace switch 20261013  # move to a dated build
agent-workspace pin              # freeze this machine to the booted digest
agent-workspace pin --clear      # unfreeze
~~~

`:previous` is published alongside `:latest` on every release, so an operator can
also move a fleet backwards with a single tag. Details and failure drills:
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
just verify    # build + container self test
~~~

Requirements: `podman` and `just`. The lint uses `shellcheck`, `actionlint` and
`jq` when they are present and skips them when they are not; CI installs all
three. It runs the same `tests/lint.sh`, `tests/install.sh` and `tests/smoke.sh`
on every pull request, so nothing is "only tested on my machine".

## Repository layout

~~~text
Containerfile            the build contract: context stage + image stage
image.env                image identity and build parameters
Justfile                 local build, sandbox, verification and disk-image recipes
install.sh               host installer: named agent containers from the image
build_files/
  build.sh               the module pipeline
  lib/common.sh          shared build helpers
  modules/<NN-name>/      one module per concern, each with module.env + install.sh
config/                  modules.conf, agents.conf - the declarative switches
system_files/            verbatim overlay copied to / (systemd, sysctl, profile.d)
runtime/                 the in-image agent-workspace CLI
scripts/                 host-side switch / rollback / doctor / cosign helpers
disk_config/             disk layout and installer customisation
tests/                   lint.sh, smoke.sh, install.sh
docs/                    architecture, modules, agents, containers, rollback
~~~

Full design notes: [docs/architecture.md](docs/architecture.md).

## First boot

A one-shot `agent-workspace-firstboot.service` creates the unprivileged
`agent` user (configurable via `AGENT_USER`, or
`/etc/agent-workspace/config.env` per machine), grants it a sub-id range so
rootless podman works, and enables lingering. A daily
`agent-workspace-health.timer` runs `agent-workspace doctor --quiet` so drift
shows up in `journalctl` instead of in a broken agent session.

## Notes and limitations

- GHCR creates a new package **private**. This project's package is public, so
  anonymous `podman pull` and `bootc switch` work; if you publish your own fork,
  flip *Packages -> agent-workspace -> Package settings -> Change visibility*.
- The default base is `ghcr.io/ublue-os/base-main:latest` (Fedora + bootc, no
  desktop). Desktop users can switch `BASE_IMAGE` to `ghcr.io/ublue-os/bluefin:stable`
  or `ghcr.io/ublue-os/aurora:stable`; minimalists can use
  `quay.io/fedora/fedora-bootc:44`.
- Disk-image builds and local VM runs need root and KVM; CI handles them in the
  `build-disk` workflow.

## Contributing

Issues and pull requests are welcome - see [CONTRIBUTING.md](CONTRIBUTING.md) and
[SECURITY.md](SECURITY.md). This project follows the
[Contributor Covenant](CODE_OF_CONDUCT.md).

## License

[MIT](LICENSE) (c) 2026 Wraindrock.

agent-workspace builds on the work of the Fedora bootc and
[Universal Blue](https://universal-blue.org/) communities; it is an independent
project and is not affiliated with either.
