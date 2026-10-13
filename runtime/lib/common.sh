#!/usr/bin/env bash
# Shared helpers for the in-image agent-workspace CLI.

MANIFEST_PATH="${MANIFEST_PATH:-/usr/share/agent-workspace/manifest.json}"
BUILD_ENV="${BUILD_ENV:-/etc/agent-workspace/build.env}"
HOST_CONFIG="${HOST_CONFIG:-/etc/agent-workspace/config.env}"
STATE_ROOT="${STATE_ROOT:-/var/lib/agent-workspace}"

log()  { printf '\033[1;34magent-workspace\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  warn\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m  fail\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31magent-workspace error:\033[0m %s\n' "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "this command must run as root (try: sudo agent-workspace $*)"
}

# is_container reports whether we are running as a plain container rather than
# as a booted system container. Rollback/switch only make sense in the latter.
is_container() {
  [[ -f /run/.containerenv || -f /.dockerenv ]]
}

# has_bootc reports whether bootc is present and talking to a booted system.
has_bootc() {
  have bootc && [[ -d /sysroot ]]
}

load_env() {
  local file
  for file in "$BUILD_ENV" "$HOST_CONFIG"; do
    # shellcheck disable=SC1090
    [[ -r "$file" ]] && . "$file"
  done
  return 0
}

image_ref() {
  load_env
  printf '%s' "${AGENT_WORKSPACE_IMAGE:-${AGENT_WORKSPACE_IMAGE_DEFAULT:-ghcr.io/wraindrock/agent-workspace}}"
}

image_version() {
  load_env
  printf '%s' "${AGENT_WORKSPACE_VERSION:-unknown}"
}

pinned_digest() {
  local file="${PinnedDigestFile:-/etc/agent-workspace/pinned-digest}"
  [[ -r "$file" ]] && tr -d '[:space:]' < "$file"
  return 0
}

manifest_field() {
  local filter="$1"
  [[ -r "$MANIFEST_PATH" ]] || return 1
  if have jq; then
    jq -r "$filter" "$MANIFEST_PATH"
  else
    grep -q . "$MANIFEST_PATH" && cat "$MANIFEST_PATH"
  fi
}
