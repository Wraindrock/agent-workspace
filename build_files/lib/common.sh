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
# rpm_installed tells whether a package name is already present in the image.
# Virtual provides count: `nodejs` is satisfied by nodejs22 and `zlib-devel`
# by zlib-ng-compat-devel, and requesting those names again is pointless.
rpm_installed() {
  rpm -q "$1" >/dev/null 2>&1 && return 0
  rpm -q --whatprovides "$1" >/dev/null 2>&1
}

# install_rpms installs a required package set; failure aborts the build.
#
# Packages that are already present are filtered out first: dnf5 aborts the
# entire transaction when a single argument cannot be resolved, so one stale
# name (for example `uidmap`, whose binaries moved into shadow-utils) would
# otherwise hide every package that is perfectly available.
install_rpms() {
  require_command dnf5
  local -a pending=()
  local pkg
  for pkg in "$@"; do
    if rpm_installed "$pkg"; then
      log "already installed: ${pkg}"
    else
      pending+=("${pkg}")
    fi
  done
  if (( ${#pending[@]} == 0 )); then
    ok "every requested package is already installed"
    return 0
  fi
  log "dnf5 install: ${pending[*]}"
  if ! dnf5 install -y --setopt=install_weak_deps=False "${pending[@]}"; then
    warn "dnf5 could not resolve every package; retrying with --skip-unavailable"
    dnf5 install -y --setopt=install_weak_deps=False --skip-unavailable "${pending[@]}" \
      || die "dnf5 could not install the required packages: ${pending[*]}"
  fi
  # A required package that silently disappears between releases must be
  # visible in the build log instead of failing later at runtime.
  for pkg in "${pending[@]}"; do
    rpm_installed "$pkg" || warn "required package is not installed: ${pkg}"
  done
}

# install_optional_rpms installs packages that are nice to have. Missing
# packages are reported but never fail the build, which keeps the image
# buildable across Fedora releases and alternative base images.
install_optional_rpms() {
  local pkg
  for pkg in "$@"; do
    if rpm_installed "$pkg"; then
      log "optional package already present: ${pkg}"
    elif dnf5 install -y --setopt=install_weak_deps=False "$pkg" >/dev/null 2>&1; then
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
# prefix so every user on the system can run them. npm's default prefix is
# /usr/local, which may not exist yet on an ostree base image.
npm_install_global() {
  require_command npm
  local prefix
  prefix="$(npm config get prefix 2>/dev/null || true)"
  [[ -n "${prefix}" ]] || prefix=/usr/local
  install -d -m 0755 "${prefix}/bin" "${prefix}/lib" 2>/dev/null || true
  log "npm install -g: $*"
  retry 3 npm install --global --no-fund --no-audit --loglevel=error "$@"
}

# pipx_install installs a Python application into /opt/pipx, exposed to all users.
pipx_install() {
  require_command pipx
  install -d -m 0755 /opt/pipx /usr/local/bin
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
