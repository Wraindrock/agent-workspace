# Modules

A module is one concern of the image: a directory, a declaration, and a function.

## The contract

```text
build_files/modules/<NN-name>/
  module.env     # declaration
  install.sh     # implementation
```

`module.env`:

~~~bash
MODULE_NAME=20-container-tools
MODULE_DESCRIPTION=Rootless podman, buildah, skopeo and the container storage stack
MODULE_ENABLED_DEFAULT=1
```

| Key | Rule |
| --- | --- |
| `MODULE_NAME` | must equal the directory name - validated by `tests/lint.sh` |
| `MODULE_DESCRIPTION` | one line, shown in the manifest |
| `MODULE_ENABLED_DEFAULT` | `0` or `1`; used only when nothing else decides |

`install.sh` must define exactly one function, `install_module()`, and is run with
the pipeline's helper library already sourced:

~~~bash
#!/usr/bin/env bash
install_module() {
  install_rpms podman buildah skopeo
  systemctl enable podman.socket
}
```

Keep the file side-effect free at load time: the pipeline sources it, then calls
the function only if the module is enabled.

## Helpers available to modules

From `build_files/lib/common.sh`:

| Helper | Behaviour |
| --- | --- |
| `log` / `ok` / `warn` / `die` | prefixed output; `die` exits the build |
| `section <title>` | visual separator in build logs |
| `require_root`, `require_command <cmd>` | fail fast on a wrong environment |
| `install_rpms <pkgs...>` | `dnf5 install` - fails the build if a package is missing |
| `install_optional_rpms <pkgs...>` | warns and continues when a package does not exist for this release |
| `retry <attempts> <cmd...>` | retries flaky network commands |
| `npm_install_global <pkgs...>` | global npm install with retries |
| `pipx_install <pkgs...>` | pipx install into `/opt/pipx` with binaries in `/usr/local/bin` |
| `record_value <key> <value>` | appends to `${STATE_DIR}/<key>` for the manifest |
| `state_read <key>` | reads it back |

## Ordering and state

Modules run in filename order. Prefixes are spaced by ten so modules can be
inserted without renaming others, and the numbering is a real ordering
dependency: `30-agent-toolchains` must exist before `40-agent-harnesses` can
install npm-based agents.

The pipeline keeps cross-module state in `${STATE_DIR}` (`/run/agent-workspace`),
which is deleted at the end of the build. `80-manifest` is the only consumer of
that state, which keeps modules from having to know about each other.

## Adding a module

1. Create `build_files/modules/<NN-name>/` with the two files above.
2. Set `MODULE_ENABLED_DEFAULT` to the right default. Be conservative: an image
   that installs everything by default is an image nobody can roll forward
   predictably.
3. Add `<NN-name>=1` or `=0` to `config/modules.conf` if you want to pin the
   repository-wide decision.
4. Run `just check` - it validates the directory, the `module.env` contract, and
   that `config/modules.conf` only references real modules.
5. Document it in `docs/modules.md`'s table in the README and rebuild with
   `just verify`.

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
| `00-preflight` | none | writes `/etc/agent-workspace/build.env`, creates `/var/lib/agent-workspace` |
| `10-base-packages` | git, git-lfs, curl, jq, rsync, openssh-clients, tar, unzip | - |
| `20-container-tools` | podman, buildah, skopeo, crun, netavark, passt, fuse-overlayfs, uidmap, podman-docker | enables `podman.socket`, writes root's sub-id range |
| `30-agent-toolchains` | gcc, make, gh, just, nodejs, npm, python3, pipx, openssl-devel | `pnpm`, `tsx`, `typescript` globally; `uv` in `/usr/local/bin` |
| `40-agent-harnesses` | the agents selected in `config/agents.conf` | installs each recipe's CLI |
| `50-devtools` | neovim, ripgrep, tmux, tree, zsh, shellcheck, direnv, fd-find, git-delta, htop | optional bat/btop/eza/starship |
| `60-system-config` | - | enables firstboot + health units, seeds `/etc/skel`, creates `/var/lib/agent-workspace/{cache,sessions}` |
| `80-manifest` | - | writes `manifest.json` and `modules.txt` |
| `90-cleanup` | - | `dnf5 clean all`, clears `/var/log` and `/tmp`, removes `${STATE_DIR}` |
