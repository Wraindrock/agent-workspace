#!/usr/bin/env bash
# Runs once per machine; see system_files/etc/systemd/system/agent-workspace-firstboot.service
set -euo pipefail

STATE_ROOT="/var/lib/agent-workspace"
MARKER="${STATE_ROOT}/.provisioned"
CONFIG="/etc/agent-workspace/config.env"

log() { printf '[agent-workspace-firstboot] %s\n' "$*"; }
warn() { printf '[agent-workspace-firstboot] warning: %s\n' "$*" >&2; }

# Defaults may be overridden by /etc/agent-workspace/config.env, which the
# container gets from the installer (--env-file) or from the image itself.
AGENT_WORKSPACE_USER="${AGENT_WORKSPACE_USER:-agent}"
AGENT_WORKSPACE_SHELL="${AGENT_WORKSPACE_SHELL:-/bin/bash}"

if [[ -r "$CONFIG" ]]; then
  # shellcheck disable=SC1090
  . "$CONFIG"
fi

# The default dsh plugin set that ships in the image, and the logic that
# decides whether to seed, refresh or leave alone the profile in the agent's
# home. Sourced after config.env so a deployment can point the two paths
# elsewhere.
LIB_DIR="${AGENT_WORKSPACE_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=/dev/null
. "${LIB_DIR}/dsh-profile.sh"

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

# ---------------------------------------------------------------------------
# Ownership of the agent's directories.
#
# The directories are always created; their ownership is best effort, and the
# two failure modes below are deliberately told apart rather than swallowed by
# a blanket `|| true`:
#
#   * Not permitted because the id is *unrepresentable*. A rootless container
#     runs in a user namespace whose uid_map frequently maps a single id
#     (`0 1000 1`), so `chown agent` is EINVAL -- and would be for every
#     possible value, because the namespace cannot name the target uid at all.
#     Nothing is broken: the agent still owns the files from inside the
#     container, the id just is not addressable from here.
#   * Anything else (ENOSPC, EROFS, EPERM on a foreign mount) is a real
#     provisioning failure and is reported as one.
#
# Neither case may abort firstboot: the completion marker below is what the
# unit's ConditionPathExists guards on, so losing it would make every boot
# re-provision and report the unit as failed forever.
# ---------------------------------------------------------------------------
declare -i owned_ok=0 owned_skipped=0 owned_failed=0

# True when the current user namespace cannot name $1 at all. `unshare -U`
# would not help: the question is whether the *current* map covers the id.
id_is_mapped() {
  local target="$1" inside outside length
  # /proc/self/uid_map columns are "inside_id outside_id length": the range
  # covered by this mapping is [inside, inside + length). Reading the second
  # column as the length (an easy slip) would widen the range to the *outside*
  # id and make unmappable uids look addressable.
  # shellcheck disable=SC2034  # `outside` is the column we must skip, not use
  while read -r inside outside length; do
    [[ -n "${length:-}" ]] || continue
    if (( target >= inside && target < inside + length )); then
      return 0
    fi
  done < /proc/self/uid_map
  return 1
}

set_owner() {
  local dir="$1" target_uid
  [[ -e "$dir" ]] || return 0

  if id_is_mapped "$(id -u "${AGENT_WORKSPACE_USER}")"; then
    if chown "${AGENT_WORKSPACE_USER}:${AGENT_WORKSPACE_USER}" "$dir" 2>/dev/null; then
      owned_ok=$((owned_ok + 1))
    else
      warn "could not set owner of ${dir} to ${AGENT_WORKSPACE_USER}: $(chown "${AGENT_WORKSPACE_USER}:${AGENT_WORKSPACE_USER}" "$dir" 2>&1 || true)"
      owned_failed=$((owned_failed + 1))
    fi
  else
    target_uid="$(id -u "${AGENT_WORKSPACE_USER}")"
    # Already ours? Then this is a no-op, not a limitation worth reporting.
    if [[ "$(stat -c '%u' "$dir")" == "$target_uid" ]]; then
      owned_ok=$((owned_ok + 1))
    else
      owned_skipped=$((owned_skipped + 1))
      log "left ${dir} owned by $(stat -c '%u:%g' "$dir"): uid ${target_uid} is not mapped in this user namespace"
    fi
  fi
}

home="$(getent passwd "${AGENT_WORKSPACE_USER}" | cut -d: -f6)"
if [[ -n "$home" && -d "$home" ]]; then
  for dir in "${home}" "${home}/agent-workspace" "${home}/agent-workspace/sessions" "${home}/.config"; do
    # Only ever create our own subdirectories; ${home} itself is the engine's
    # (it is a volume in the installer's layout) and must not be re-created.
    [[ "$dir" == "$home" ]] || install -d -m 0755 "$dir"
    set_owner "$dir"
  done
fi

log "ownership: ${owned_ok} ok, ${owned_skipped} not mapped by this user namespace, ${owned_failed} failed"

# Keep user services (including rootless podman) alive across sessions.
if loginctl enable-linger "${AGENT_WORKSPACE_USER}" 2>/dev/null; then
  log "enabled linger for ${AGENT_WORKSPACE_USER}"
elif [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}${DBUS_SYSTEM_BUS_ADDRESS:-}" ]]; then
  warn "could not enable linger for ${AGENT_WORKSPACE_USER}"
else
  # Inside a container there is normally no system bus to ask, and systemd's
  # own logind is not the one that would honour the request anyway.
  log "skipped linger for ${AGENT_WORKSPACE_USER}: no system bus in this environment"
fi

# ---------------------------------------------------------------------------
# The image's default dsh plugin set.
#
# dsh reads profiles from the agent's $HOME/.dsh, which lives in the volume the
# installer mounts, so the image's copy is seeded here -- before the completion
# marker below, which is what the container's readiness probe waits for. A
# failure is counted and reported, never fatal: the marker must still be
# written, and the agent can create the profile later with `dsh plugin`.
# ---------------------------------------------------------------------------
if [[ -n "$home" && -d "$home" ]]; then
  # shellcheck disable=SC2015
  seed_dsh_profiles "$home" "${AGENT_WORKSPACE_USER}" ||
    warn "the image's dsh plugin set was not fully seeded; the agent can install it with: dsh plugin --profile web install"
fi

# The marker is written last and unconditionally: it is what makes firstboot
# idempotent. Re-running this script is a no-op for every step above (users,
# sub-ids and directories are only created when missing, and ownership is
# never forced onto content that is already correct), and $STATE_ROOT is only
# filled in, never cleared, so nothing a user put there is removed.
install -d -m 0755 "$STATE_ROOT"
touch "$MARKER"
log "done"
