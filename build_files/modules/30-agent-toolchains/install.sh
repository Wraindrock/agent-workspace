#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../lib/common.sh
source "${COMMON_LIB:?COMMON_LIB must point at build_files/lib/common.sh}"

# --- required toolchains ---------------------------------------------------
install_rpms \
  gcc \
  gcc-c++ \
  gh \
  just \
  make \
  nodejs \
  npm \
  openssl-devel \
  python3 \
  python3-devel \
  python3-pip \
  python3-wheel \
  pipx \
  zlib-devel

# --- global node tooling ---------------------------------------------------
# pnpm and tsx are the de-facto entry points of modern agent harnesses.
npm_install_global pnpm tsx typescript

# --- python tooling --------------------------------------------------------
pipx ensurepath --global || warn "pipx ensurepath failed"

# uv ships in most Fedora releases; fall back to the upstream installer.
if ! dnf5 install -y --setopt=install_weak_deps=False uv >/dev/null 2>&1; then
  warn "uv is unavailable in the enabled repos, using the upstream installer"
  retry 3 bash -c "curl -LsSf https://astral.sh/uv/install.sh | UV_INSTALL_DIR=/usr/local/bin sh"
fi

node --version | sed 's/^/node /' | while read -r v; do record_value tool "$v"; done
python3 --version | sed 's/^/python /' | while read -r v; do record_value tool "$v"; done
