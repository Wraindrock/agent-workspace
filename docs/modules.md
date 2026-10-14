# Modules

A module is one concern of the image: a directory, a declaration, and a script.

## The contract

```text
build_files/modules/<NN-name>/
  module.env     # declaration
  install.sh     # implementation
```

`module.env`:

~~~bash
MODULE_NAME=20-container-tools
MODULE_DESCRIPTION="Rootless podman, buildah, skopeo and the container storage stack"
MODULE_ENABLED_DEFAULT=1
~~~

Quote every value. The pipeline `source`s this file, so an unquoted description
with spaces is parsed as a command and the build dies with
`base: command not found`.

| Key | Rule |
| --- | --- |
| `MODULE_NAME` | must equal the directory name - validated by `tests/lint.sh` |
| `MODULE_DESCRIPTION` | one line, shown in the build log |
| `MODULE_ENABLED_DEFAULT` | `0` or `1`; used only when nothing else decides |

`install.sh` is an executable script, not a function library: the pipeline runs
it as a child process with `MODULE_NAME` and `MODULE_DIR` exported and the module
directory as its working directory. Nothing sources it, and the helper library is
not pre-loaded, so a script that wants the helpers sources `$COMMON_LIB` itself:

~~~bash
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../lib/common.sh
source "${COMMON_LIB:?COMMON_LIB must point at build_files/lib/common.sh}"

install_rpms podman buildah skopeo
systemctl enable podman.socket
~~~

The pipeline runs `install.sh` only when the module is enabled, so the script
needs no enabled check of its own.

## Helpers available to modules

From `build_files/lib/common.sh`:

| Helper | Behaviour |
| --- | --- |
| `log` / `ok` / `warn` / `die` | prefixed output; `die` exits the build |
| `section <title>` | visual separator in build logs |
| `require_root`, `require_command <cmd>` | fail fast on a wrong environment |
| `install_rpms <pkgs...>` | `dnf5 install` for a required set: already-installed packages are filtered out, a failed transaction is retried with `--skip-unavailable`, and every package is verified afterwards |
| `install_optional_rpms <pkgs...>` | warns and continues when a package does not exist for this release |
| `rpm_installed <pkg>` | true when the package - or anything providing it - is already in the image |
| `retry <attempts> <cmd...>` | retries flaky network commands |
| `npm_install_global <pkgs...>` | global npm install with retries, cached under `/var/cache/agent-workspace/npm` |
| `pipx_install <pkgs...>` | pipx install into `/opt/pipx` with binaries in `/usr/local/bin` |
| `enable_unit <unit>` | enables a unit during an image build, falling back to `systemctl --root=/ enable` |
| `record_value <key> <value>` | appends one value to the build state that `80-manifest` reads |
| `state_read <key>` | reads it back |

## Ordering and state

Modules run in filename order. Prefixes are spaced by ten so modules can be
inserted without renaming others, and the numbering is a real ordering
dependency: `30-agent-toolchains` must exist before `40-agent-harnesses` can
install npm-based agents.

The pipeline keeps cross-module state in `${STATE_DIR}` (`/run/agent-workspace`),
which is deleted at the end of the build. `80-manifest` and the build summary in
`build_files/build.sh` read that state, which keeps modules from having to know
about each other.

## Adding a module

1. Create `build_files/modules/<NN-name>/` with the two files above.
2. Set `MODULE_ENABLED_DEFAULT` to the right default. Be conservative: an image
   that installs everything by default is an image nobody can roll forward
   predictably.
3. Add `<NN-name>=1` or `=0` to `config/modules.conf` if you want to pin the
   repository-wide decision.
4. Run `just check` - it validates the directory, the `module.env` contract, and
   that `config/modules.conf` only references real modules.
5. Add it to the module tables in `README.md` and `docs/modules.md`, then
   rebuild with `just verify`.

## Turning modules off

```bash
# repository-wide: edit config/modules.conf
30-agent-toolchains=0

# or for a single build, ignoring the config file
podman build --build-arg IMAGE_MODULES=00-preflight,10-base-packages -t slim .
```

Anything disabled is absent from the manifest, so a slim image still explains
itself truthfully.

## Module reference

| Module | Packages / actions | Notable side effects |
| --- | --- | --- |
| `00-preflight` | none | writes `/etc/agent-workspace/build.env` (base image, version, Fedora release), creates `/usr/share/agent-workspace`, `/usr/lib/agent-workspace`, `/etc/agent-workspace` and `/var/lib/agent-workspace`, and materialises the `/home`, `/opt`, `/usr/local` and `/root` symlink targets (`/var/home`, `/var/opt`, `/var/usrlocal`, `/var/roothome`) |
| `10-base-packages` | bash-completion, bind-utils, ca-certificates, curl, dnf5-plugins, findutils, git, git-lfs, gnupg2, hostname, iproute, iputils, jq, less, openssh-clients, procps-ng, psmisc, rsync, sudo, tar, unzip, which, wget, xz, zip, zstd (optional `yq`) | installs the git-lfs system hooks |
| `20-container-tools` | podman, buildah, skopeo, crun, fuse-overlayfs, netavark, aardvark-dns, catatonit, passt, podman-docker (optional containernetworking-plugins, slirp4netns) | enables `podman.socket`, writes root's sub-id range, creates `/etc/containers/registries.conf.d`, warns when `newuidmap` is missing |
| `30-agent-toolchains` | gcc, gcc-c++, gh, just, make, nodejs, npm, openssl-devel, python3, python3-devel, python3-pip, python3-wheel, pipx, zlib-devel | `pnpm`, `tsx`, `typescript` globally; `uv` in `/usr/local/bin`, installed from the upstream script when the package is unavailable; records the node and python versions |
| `40-agent-harnesses` | the agents selected in `config/agents.conf` | installs each recipe's CLI and records its binaries, title and credential variable |
| `50-devtools` | neovim, ripgrep, tmux, tree, zsh, ShellCheck, direnv, fd-find, git-delta, htop, make (optional bat, btop, eza, starship) | symlinks `fd` and `bat` to their conventional names |
| `60-system-config` | - | enables the firstboot and health units, applies presets, seeds `/etc/skel`, creates `/var/lib/agent-workspace/{cache,sessions}` |
| `80-manifest` | - | writes `manifest.json` (including `agentBinaries` and `agentCatalog`) and `modules.txt` |
| `90-cleanup` | - | `dnf5 clean all`, clears `/var/log`, `/tmp`, `/var/tmp` and `/run/dnf`, removes `/var/cache/dnf`, `/var/cache/libdnf5`, `/var/cache/PackageKit`, `/var/cache/agent-workspace` and the pipx log/cache under `/var/opt/pipx`; the build state is removed by `build_files/build.sh` after the summary |
