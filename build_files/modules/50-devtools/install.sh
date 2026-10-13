#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../lib/common.sh
source "${COMMON_LIB:?COMMON_LIB must point at build_files/lib/common.sh}"

install_rpms \
  ShellCheck \
  direnv \
  fd-find \
  git-delta \
  htop \
  make \
  neovim \
  ripgrep \
  tmux \
  tree \
  zsh

# Nice to have. These packages come and go between Fedora releases, so a
# missing one is reported and skipped instead of failing the build.
install_optional_rpms bat btop eza starship

# fd-find is packaged as `fd`, delta as `delta`: make both discoverable
# under their conventional names without shadowing anything.
for alias_pair in "fd:fd-find" "bat:batcat"; do
  binary="${alias_pair%%:*}"; package_name="${alias_pair##*:}"
  if ! command -v "$binary" >/dev/null 2>&1 && command -v "$package_name" >/dev/null 2>&1; then
    ln -sf "$(command -v "$package_name")" "/usr/local/bin/$binary"
  fi
done
