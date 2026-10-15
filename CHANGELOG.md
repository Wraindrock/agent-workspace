# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
for the *declarative surface* - `config/*.conf`, `image.env`, `install.sh`, and the
`agent-workspace` CLI. Day-to-day image builds are identified by tag
(`YYYYMMDD`, `YYYYMMDD-<sha>`) rather than by version number.

## [Unreleased]

### Added

- The installer speaks Simplified Chinese. Messages now come from a keyed catalogue
  (`installer/lib/i18n.sh`) instead of English string literals, and the locale is
  resolved as `LC_ALL` -> `LC_MESSAGES` -> `LANG`, with `AW_LANG_OVERRIDE` to force
  one. An unsupported locale falls back to English as a whole rather than mixing
  languages. `tests/i18n.sh` fails if any message bypasses the catalogue, if a key is
  defined twice, or if the command and flag column of `--help` differs between the two
  languages - a translation could otherwise rename a flag without any test noticing.
  Four things stay English on purpose: the `bash 4.4` guard and the bootstrap's
  "fetched N files" line (printed before the catalogue is available), the
  `CONTAINER=`/`NAME` declaration format (machine-readable), and the `dry-run` label
  with the engine command it prints (a copyable shell command).

### Fixed

- A snapshot taken in the same second as a deleted one could be handed an id that
  sorted *before* a snapshot that still existed, because ids are second-granular
  and the collision loop only skipped ids that were currently taken - deleting a
  snapshot frees its id again. Two silent consequences: `--keep N` pruned the very
  snapshot it had just committed, and `latest`, `recover` and `rollback --to latest`
  resolved to an older snapshot. The id now grows off whichever id is currently
  greatest whenever the raw timestamp would not sort after it, which also keeps ids
  monotonic when the clock steps backwards. `cmd_snapshot` takes its id from the new
  `snapshot_next_id()` instead of stamping the clock itself. `tests/contract.sh`
  asserts the edge cases directly, and `tests/install.sh` pins them on a frozen
  clock: a PATH whose `date` freezes the snapshot second, so "the newest snapshot is
  the one just taken" is asserted without depending on how fast the suite runs.

- A destructive subcommand no longer reports success when it was never confirmed.
  `remove`, `rollback` and `upgrade` read their confirmation from stdin; with no
  terminal that read hit EOF, `confirm` returned "no", and the caller returned 0 - so
  `install.sh remove box && ...` ran its success branch while the container was still
  there. `confirm` now refuses outright when there is no terminal and no `--yes`,
  which is the same rule `create` already followed, and a declined destructive command
  exits non-zero. `tests/install.sh` asserts the exit status, the refusal message, that
  the container and its volume are still there, and that no success was claimed.

- `install.sh fork SRC DST` with only one argument died with an English message, and
  `--file` with a missing declaration file, an unknown `--agent` in the menu, and an
  unparsable menu key did the same. `tests/i18n.sh` now sweeps `install.sh` as well as
  `installer/lib/*.sh` for messages that bypass the catalogue, which is how these four
  were missed: the earlier sweep only looked at the library.

## [0.1.2] - 2026-10-15

The project stops depending on the host's kernel, and starts enforcing the
surface it promises not to break.

### Fixed

- The image no longer ships `/etc/sysctl.d/90-agent-workspace.conf`. It could not
  work: the kernel charges inotify instances per *uid*, so a container always read
  the host session's value rather than the image's, while `fs.inotify.*` and
  `vm.max_map_count` are not namespaced and the engine rejects them outright
  (`Error: sysctl 'fs.inotify.max_user_instances' is not allowed`). The file was a
  promise the image could not keep; what remains is the host's business. Neither
  `install.sh` nor any documented workaround writes to `/etc/sysctl.d` any more.
  `tests/smoke.sh` asserts the file is *absent*, and `tests/decoupling.sh` fails if
  it comes back.
- `firstboot` provisioning completes even when the container's user namespace
  cannot name the agent's uid. It used `install -d -o agent -g agent` on the
  agent's home, which is a volume: a rootless container whose `uid_map` covers a
  single id answered `install: cannot change owner and permissions of
  '/var/home/agent/agent-workspace': Invalid argument`, and `set -euo pipefail`
  aborted the unit before it wrote `/var/lib/agent-workspace/.provisioned`. The
  completion marker was then never written, the unit reported `failed`, and every
  boot re-provisioned. Ownership is now best effort and tells the two cases apart:
  a uid the namespace cannot represent is logged as such and skipped (the agent
  still owns the files from inside the container), while a real failure - `ENOSPC`,
  `EROFS`, `EPERM` on a foreign mount - is reported as one. The marker is written
  last and unconditionally, so firstboot is idempotent. `loginctl enable-linger`
  no longer reports a bus-less container as an error either.

### Added

- `tests/contract.sh` - 168 assertions freezing the declarative surface that
  `CHANGELOG.md` says SemVer covers: the `install.sh` subcommands and their
  options, the `config/*.conf` and `image.env` keys, and the `agent-workspace`
  CLI's subcommands. A pull request that changes the public surface now fails CI
  until the change is declared.
- `tests/portability.sh` - asserts the image boots on a host whose kernel settings
  were never tuned: PID 1 has to come up as systemd and the container has to stay
  running. It *records* the host's `fs.inotify.max_user_instances` instead of
  demanding a value, so a tuned host is not a precondition
  (`AW_PORTABILITY_REQUIRE_STOCK=1` opts into the strict form).
- `tests/decoupling.sh` - the behavioural half of the decoupling contract: the
  sysctl drop-in stays deleted, `doctor` no longer requires it, and no test script
  hard-codes `podman` instead of reaching the engine through a configurable
  variable. Its assertions are themselves checked against a predicate that must be
  able to fail, so they cannot decay into decoration.
- `tests/firstboot.sh` - the provisioning contract: the marker is written last and
  unconditionally, the unit keeps its `ConditionPathExists` guard, an unrepresentable
  uid is skipped rather than fatal, and `/proc/self/uid_map` columns are read in the
  right order.
- `just verify-all`, and `just static` / `just static-all` for the engine-free half.
  `just verify` now reaches `containers-full` - it silently dropped
  `tests/integration.sh` before, because `just` allows one `&&` chain per recipe.

### Changed

- CI runs all eight test scripts on every pull request, and `tests/lint.sh` fails
  if a script exists that CI does not run.
- `tests/smoke.sh` takes the engine from `AW_SMOKE_ENGINE` (default `podman`)
  instead of pinning itself to one engine, matching the rest of the suite.
- `tests/integration.sh` removes the installer's state directory when it cleans up.
  It only removed the container, so the second run in a row saw `install.sh create`
  report "already managed; skipping" and then failed on the container it never
  created. The suite is a green-then-red trap no longer.
- The inotify exhaustion diagnosis in `docs/containers.md` and
  `tests/integration.sh` reports the host's own numbers (`max_user_instances`, the
  live instance count) and points at the session rather than asking for `sudo`.
  `docs/architecture.md` records "no host kernel tuning, and no `sudo` for it" as a
  deliberate non-goal.
- README and `docs/` corrections: the module-60 description no longer claims sysctl
  tuning, the test lists name all eight scripts, and the repository layout matches
  the tree.

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

[0.1.2]: https://github.com/wraindrock/agent-workspace/releases/tag/v0.1.2
[0.1.1]: https://github.com/wraindrock/agent-workspace/releases/tag/v0.1.1
[0.1.0]: https://github.com/wraindrock/agent-workspace/releases/tag/v0.1.0
