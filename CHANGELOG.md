# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
for the *declarative surface* - `config/*.conf`, `image.env`, `install.sh`, and the
`agent-workspace` CLI. Day-to-day image builds are identified by tag
(`YYYYMMDD`, `YYYYMMDD-<sha>`) rather than by version number.

## [0.1.0] - 2026-10-13

The first release: a declarative Fedora bootc image plus the installer that runs
it as isolated agent containers.

### Added

- `install.sh`, the single supported entry point: a [gum](https://github.com/charmbracelet/gum)
  TUI (with a plain `read` fallback when gum or a terminal is missing) that
  creates named agent containers on `podman` or `docker`, plus the
  non-interactive subcommands `create`, `list`, `start`, `stop`, `restart`,
  `enter`, `logs`, `snapshot`, `snapshots`, `rollback`, `recover`, `fork`,
  `upgrade`, `web`, `remove` and `doctor`.
- Container lifecycle and rollback, entirely on the host: `snapshot` commits the
  container filesystem to a local image and archives `/home/agent`; `rollback`
  recreates the container from a snapshot; `recover` starts, restores or rebuilds
  a container that went missing; `fork` copies a container into a second one;
  `upgrade` takes a `pre-upgrade` snapshot before it pulls a new image. Retention
  defaults to the latest five snapshots (`--keep`, `SNAPSHOT_KEEP`).
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
  agent its commands, its title and its credential variable, so the installer
  menu and `agent-workspace agents` describe exactly what a build ships.
- The in-image `agent-workspace` CLI: `version`, `manifest`, `modules`,
  `agents`, `status` and `doctor --strict`.
- First-boot provisioning (`agent-workspace-firstboot.service`) that creates the
  unprivileged agent user with a sub-id range and enables lingering, guarded so
  it runs exactly once per container.
- A daily `agent-workspace-health.timer` running `doctor --quiet`.
- A machine-readable build manifest at `/usr/share/agent-workspace/manifest.json`
  and its shell-accessible counterpart `/etc/agent-workspace/build.env`.
- CI (`build.yml`): lint (shellcheck, actionlint, `just --list`), build, container
  self test, push to GHCR, and keyless cosign signing plus verification of the
  digest the registry actually stored.
- `tests/lint.sh`, `tests/smoke.sh`, `tests/install.sh` (a fake podman/docker
  engine in `tests/fixtures/fake-engine.sh`), run both locally through the
  Justfile and in CI.
- Documentation: `README.md`, `README.zh-CN.md`, `docs/architecture.md`,
  `docs/modules.md`, `docs/agents.md`, `docs/containers.md`, `docs/rollback.md`.
- Project files: MIT `LICENSE`, `CONTRIBUTING.md`, `SECURITY.md`,
  `CODE_OF_CONDUCT.md`, issue and pull request templates, Dependabot and
  Renovate configuration.

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
- `00-preflight` materialises the `/usr/local` and `/root` symlink targets,
  fixing `ENOTDIR` failures in npm and pipx installers.
- `90-cleanup` no longer removes the build state that the build summary still
  reads.

[0.1.0]: https://github.com/wraindrock/agent-workspace/releases/tag/v0.1.0
