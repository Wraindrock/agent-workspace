#!/usr/bin/env bash
# Shared helpers for agent-workspace build modules.
# Sourced (never executed) by build.sh and every modules/*/install.sh.

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log()  { printf '\033[1;34m[agent-workspace]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[agent-workspace]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[agent-workspace] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[agent-workspace] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

section() {
  printf '\n\033[1;35m=== %s ===\033[0m\n' "$*"
}

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "build modules must run as root"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# ---------------------------------------------------------------------------
# systemd
# ---------------------------------------------------------------------------
# enable_unit enables a unit inside an image build, where PID 1 is not systemd.
# Plain `systemctl enable` handles that case on current systemd; the explicit
# offline form `systemctl --root=/ enable` is the fallback.
enable_unit() {
  local unit="$1"
  if systemctl enable "${unit}" >/dev/null 2>&1; then
    ok "enabled ${unit}"
    return 0
  fi
  if systemctl --root=/ enable "${unit}" >/dev/null 2>&1; then
    ok "enabled ${unit} (offline)"
    return 0
  fi
  die "could not enable ${unit}"
}

# ---------------------------------------------------------------------------
# Package helpers (Fedora / dnf5)
# ---------------------------------------------------------------------------
# install_rpms installs a required package set; failure aborts the build.
install_rpms() {
  log "dnf5 install: $*"
  dnf5 install -y --setopt=install_weak_deps=False "$@"
}

# install_optional_rpms installs packages that are nice to have. Missing
# packages are reported but never fail the build, which keeps the image
# buildable across Fedora releases and alternative base images.
install_optional_rpms() {
  local pkg
  for pkg in "$@"; do
    if dnf5 install -y --setopt=install_weak_deps=False "$pkg" >/dev/null 2>&1; then
      ok "optional package installed: ${pkg}"
    else
      warn "optional package unavailable on this base: ${pkg} (skipped)"
    fi
  done
}

# ---------------------------------------------------------------------------
# Network installers
# ---------------------------------------------------------------------------
# retry <attempts> <command...> - retries flaky network operations.
retry() {
  local attempts="$1"; shift
  local n=1
  until "$@"; do
    if (( n >= attempts )); then
      die "command failed after ${attempts} attempts: $*"
    fi
    warn "attempt ${n}/${attempts} failed, retrying: $*"
    n=$((n + 1))
    sleep $((n * 3))
  done
}

# npm_install_global installs one or more npm packages into the image-wide
# prefix so every user on the system can run them.
npm_install_global() {
  require_command npm
  log "npm install -g: $*"
  retry 3 npm install --global --no-fund --no-audit --loglevel=error "$@"
}

# pipx_install installs a Python application into /opt/pipx, exposed to all users.
pipx_install() {
  require_command pipx
  log "pipx install: $*"
  PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin retry 3 pipx install --force "$@"
}

# ---------------------------------------------------------------------------
# Declarative state
# ---------------------------------------------------------------------------
# state_read prints the recorded values for a key from the build state dir.
state_read() {
  local file="${STATE_DIR:-/run/agent-workspace}/${1}"
  [[ -f "$file" ]] && cat "$file"
  return 0
}

# record_key/value appends declarative facts that later modules (and the image
# manifest) consume instead of re-deriving them.
record_value() {
  local file="${STATE_DIR:?STATE_DIR must be set}/${1}" value="$2"
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$value" >> "$file"
}
