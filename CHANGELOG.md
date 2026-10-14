# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
for the *declarative surface* - `config/*.conf`, `image.env`, `install.sh`, and the
`agent-workspace` CLI. Day-to-day image builds are identified by tag
(`YYYYMMDD`, `YYYYMMDD-<sha>`) rather than by version number.

## [0.1.1] - 2026-10-14

The container `install.sh` creates now actually boots. Both fixes live in the
image, so a new container - or `install.sh upgrade` - picks them up.

### Fixed

- The image names systemd as its own command (`CMD ["/sbin/init"]`). `podman run
  --systemd=always` does not replace a container's command (checked against
  podman 5.8.4), so every container inherited the base image's `/usr/bin/bash`,
  exited within milliseconds, and `install.sh create` reported a container that
  never ran.
- `00-preflight` materialises `/var/home` for the dangling `/home` symlink,
  which is what made `install.sh create` fail outright with `crun: creating
  '/home/agent': openat2 'home': No such file or directory`: the engine has to
  create the agent home volume's mount point inside the container.
  `verify_layout` and `tests/smoke.sh` now cover `/home` as well.
- `install.sh create` waits for the container to reach `running` (a bounded
  liveness probe, not a fixed sleep) and fails with the container's own log lines
  when it does not, instead of reporting a container that never started.
  `tests/install.sh` covers that path with an engine whose container exits on
  start.

### Added

- `tests/integration.sh`: boots the image through `install.sh` on the real
  engine and asserts that the container runs, that PID 1 is systemd and that
  `/home/agent` is a mounted volume. CI ran no real container before this, and
  `just verify` now runs it too.

## [0.1.0] - 2026-10-13

The first release: a declarative Fedora bootc image plus the installer that runs
it as isolated agent containers.

### Added

- `install.sh`, the single supported entry point: a [gum](https://github.com/charmbracelet/gum)
  TUI whose menu needs gum and a terminal; individual prompts fall back to a
  plain `read`. It creates named agent containers on `podman` or `docker`, plus
  the non-interactive subcommands `create`, `list`, `start`, `stop`, `restart`,
  `enter`, `shell`, `logs`, `snapshot`, `snapshots`, `rollback`, `recover`, `fork`,
  `upgrade`, `web`, `remove` and `doctor`.
- Container lifecycle and rollback, entirely on the host: `snapshot` commits the
  container filesystem to a local image and archives `/home/agent`; `rollback`
  recreates the container from a snapshot; `recover` starts, restores or rebuilds
  a container that went missing; `fork` copies a container into a second one;
  `upgrade` takes a `pre-upgrade` snapshot before it pulls a new image. Retention
  defaults to the latest five snapshots (`--keep`, `SNAPSHOT_KEEP`).
- Safety before destruction: `rollback` verifies that the snapshot's home archive
  can be read before it changes anything, refuses to continue when it cannot, and
  snapshots the container it replaces first (label `pre-rollback`, `--skip-safety` to
  turn that off). `snapshot` deletes a home archive it cannot read back, keeping the
  filesystem snapshot. Retention keeps any snapshot whose image a container
  still runs from - including containers this installer does not manage - and
  reports which container it was. `remove --purge-snapshots` keeps that image
  and reports the container too, but deletes the snapshot record and its home
  archive.
- Per-container credential files at
  `~/.config/agent-workspace/containers/<name>.env` (mode 600, passed to the
  engine with `--env-file`) and per-container host state under
  `~/.local/share/agent-workspace/`.
- Engine flags per container: `podman` gets `--systemd=always --restart unless-stopped`
  and a named `/home/agent` volume; `docker` additionally gets
  `--privileged --cgroupns=host` with `/sys/fs/cgroup` mounted read-write and
  `/run`, `/tmp` as tmpfs.
- `Containerfile` with a `ctx` build stage, OCI/Artifact Hub labels, a single
  pipeline `RUN`, and `bootc container lint` as the final gate.
- The agent's web UI on your host: `./install.sh web NAME` starts `dsh web` inside the
  container as the agent user and prints a one-time `?token=` link for
  `http://127.0.0.1:<port>/` (the token sets a 30-day cookie). The host port is chosen
  when the container is created and recorded with it, so `rollback`, `recover` and
  `upgrade` keep working links; `--web-port N` picks one, `--no-web` leaves the
  container unpublished. Publishing is always `127.0.0.1:<host port>:3080`, never a
  network interface.
- `/usr/share/agent-workspace/dsh-web.yml` in the image: the `dsh` overlay that lets
  the web UI bind the container's own interface, since `dsh` refuses anything but
  loopback by default. It is passed as `--patch` and replaces only the `webserver`
  entry (`host` and `port`).
- The module pipeline: `build_files/build.sh` plus `build_files/lib/common.sh`,
  with three-level enable resolution (`IMAGE_MODULES` build argument,
  `config/modules.conf`, `MODULE_ENABLED_DEFAULT`).
- Nine modules: `00-preflight`, `10-base-packages`, `20-container-tools`,
  `30-agent-toolchains`, `40-agent-harnesses`, `50-devtools`,
  `60-system-config`, `80-manifest`, `90-cleanup`.
- Agent recipes for DSH, OpenCode, Claude Code, Codex CLI, Gemini CLI and Aider,
  selected through `config/agents.conf` (`dsh` and `opencode` by default).
- `agentCatalog` and `agentBinaries` in the image manifest: for every installed
  agent its commands, its title and its credential variable. The installer menu
  starts from the built-in `dsh`/`opencode` entries and merges the image's
  catalog over them, so it can offer an agent the image does not contain;
  `agent-workspace agents` reports the running image's manifest.
- The in-image `agent-workspace` CLI: `version`, `manifest`, `modules`,
  `agents`, `status` and `doctor --strict`.
- First-boot provisioning (`agent-workspace-firstboot.service`) that creates the
  `agent` user (a `wheel` member with a sub-id range; the container is not a
  security boundary against the agent) and enables lingering, guarded so it runs
  exactly once per container.
- A daily `agent-workspace-health.timer` running `doctor --quiet`.
- A machine-readable build manifest at `/usr/share/agent-workspace/manifest.json`
  and its shell-accessible counterpart `/etc/agent-workspace/build.env`.
- CI (`build.yml`): lint (shellcheck, actionlint, `just --list`, python3/pyyaml),
  the installer integration tests (`tests/install.sh`, no engine required), build,
  container self test, push to GHCR, and keyless cosign signing plus verification
  of the digest the registry actually stored.
- `tests/lint.sh`, `tests/smoke.sh`, `tests/install.sh` (a fake podman/docker
  engine in `tests/fixtures/fake-engine.sh`), run both locally through the
  Justfile and in CI.
- Documentation: `README.md`, `README.zh-CN.md`, `docs/architecture.md`,
  `docs/modules.md`, `docs/agents.md`, `docs/containers.md`, `docs/rollback.md`.
- Project files: MIT `LICENSE`, `CONTRIBUTING.md`, `SECURITY.md`,
  `CODE_OF_CONDUCT.md`, a `.mailmap` that folds the historical author spellings
  into one identity, issue and pull request templates, Dependabot and Renovate
  configuration.

### Changed

- `AGENT_BINARIES`, `AGENT_TITLE` and `AGENT_ENV` are the recipe contract;
  `agent-workspace agents` and `doctor` check the declared binaries instead of
  deriving a command name from the recipe name.
- `install_rpms` filters out packages that are already installed, retries a
  failed transaction with `--skip-unavailable`, and warns per missing package
  instead of failing the whole build on Fedora package churn.
- CI authenticates podman and cosign through an explicit authfile, and signs the
  digest the registry actually stored (read back with a HEAD request) rather than
  a locally computed one.

### Removed

- The bootc disk-image path: `disk_config/`, `.github/workflows/build-disk.yml`,
  the Justfile `build-qcow2` / `build-iso` / `run-vm` recipes, the host
  `scripts/{switch,rollback,doctor}.sh` helpers, and the in-image `switch`,
  `rollback`, `update` and `pin` subcommands. Rollback now applies to the
  containers `install.sh` creates, not to the host system.

### Fixed

- `module.env` descriptions are quoted, so sourcing the file cannot execute them.
- `00-preflight` materialises the `/opt`, `/usr/local` and `/root` symlink targets
  (`/var/opt`, `/var/usrlocal`, `/var/roothome`), fixing `ENOTDIR` failures in npm
  and pipx installers. `/opt` was the missing one: every build logged
  `WARN: pipx ensurepath failed`, and the opt-in `aider` recipe aborted the build
  with `install: cannot create directory '/opt': File exists`. The `verify_layout`
  step at the end of `build.sh` now fails the build when any of the three is left
  dangling.
- The image ships no build junk in runtime-only directories: `90-cleanup` removes
  `/run/dnf` and the pipx log and cache directories under `/var/opt/pipx`, and
  every npm invocation (including `npm config get prefix`) keeps its cache and
  debug logs next to the cache `90-cleanup` removes instead of in `$HOME/.npm`.
  These are the `nonempty-run-tmp` and `var-tmpfiles` findings of
  `bootc container lint`, and CI now fails the build when `/run` is not empty.
- `90-cleanup` no longer removes the build state that the build summary still
  reads.
- `install.sh web` prints the port as a port (`http://127.0.0.1:3080/`), not as a
  path segment (`http://127.0.0.1/3080/`).
- Documentation that the code did not support is corrected: the lint tool list and
  the CI test list, the `install.sh` subcommand list (`shell` was missing), the
  module and agent recipe contracts, which user the container runs the agent as,
  and the snapshot guarantees that `doctor` checks.

[0.1.1]: https://github.com/wraindrock/agent-workspace/releases/tag/v0.1.1
[0.1.0]: https://github.com/wraindrock/agent-workspace/releases/tag/v0.1.0
