#!/usr/bin/env bash
# Runs once per machine; see system_files/etc/systemd/system/agent-workspace-firstboot.service
set -euo pipefail

STATE_ROOT="/var/lib/agent-workspace"
MARKER="${STATE_ROOT}/.provisioned"
CONFIG="/etc/agent-workspace/config.env"

log() { printf '[agent-workspace-firstboot] %s\n' "$*"; }

# Defaults may be overridden by /etc/agent-workspace/config.env, which the
# container gets from the installer (--env-file) or from the image itself.
AGENT_WORKSPACE_USER="${AGENT_WORKSPACE_USER:-agent}"
AGENT_WORKSPACE_SHELL="${AGENT_WORKSPACE_SHELL:-/bin/bash}"

if [[ -r "$CONFIG" ]]; then
  # shellcheck disable=SC1090
  . "$CONFIG"
fi

log "provisioning user ${AGENT_WORKSPACE_USER}"

if ! id "${AGENT_WORKSPACE_USER}" >/dev/null 2>&1; then
  useradd --create-home --shell "${AGENT_WORKSPACE_SHELL}" --groups wheel "${AGENT_WORKSPACE_USER}"
  log "created user ${AGENT_WORKSPACE_USER}"
else
  log "user ${AGENT_WORKSPACE_USER} already exists"
fi

# Rootless podman needs a sub-id range.
if ! grep -q "^${AGENT_WORKSPACE_USER}:" /etc/subuid 2>/dev/null; then
  usermod --add-subuids 524288-589823 --add-subgids 524288-589823 "${AGENT_WORKSPACE_USER}"
  log "allocated a sub-id range to ${AGENT_WORKSPACE_USER}"
fi

home="$(getent passwd "${AGENT_WORKSPACE_USER}" | cut -d: -f6)"
if [[ -n "$home" && -d "$home" ]]; then
  install -d -o "${AGENT_WORKSPACE_USER}" -g "${AGENT_WORKSPACE_USER}" -m 0755     "${home}/agent-workspace" "${home}/agent-workspace/sessions" "${home}/.config"
fi

# Keep user services (including rootless podman) alive across sessions.
loginctl enable-linger "${AGENT_WORKSPACE_USER}" || log "could not enable linger"

install -d -m 0755 "$STATE_ROOT"
touch "$MARKER"
log "done"
