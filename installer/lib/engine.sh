#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Backend abstraction: one interface over every way this installer can run a
# workspace.
#
# A backend is a name (podman, docker, incus) plus an implementation file,
# installer/lib/backend-<name>.sh, that defines the same set of verbs:
#
#   eng_version                 the backend's own version line
#   eng_container_exists        does an instance by this name exist
#   eng_container_running       1 when it is running
#   eng_container_status        running/exited/... or "missing"
#   eng_container_image         the image the instance was created from
#   eng_labeled_containers      every instance carrying our labels
#   eng_volume_exists           is the backing home volume there
#   eng_image_exists            is the image present locally
#   eng_image_id                short id of the local image (display only)
#   eng_image_created           build time of the local image (display only)
#   eng_host_port               host address a published port is bound to
#   eng_pull                    fetch an image
#   eng_image_remove            drop a local image
#   eng_image_run               run a one-shot command out of an image
#   eng_create_persistent       create the long-lived workspace instance
#   eng_create_ephemeral        create the one-shot instance
#   eng_start / eng_stop        start, stop
#   eng_remove                  delete the instance (and nothing else)
#   eng_volume_create / eng_volume_remove
#   eng_exec                    interactive shell command in the instance
#   eng_exec_nofail             non-interactive command, status discarded
#   eng_logs                    the instance's console log
#   eng_commit                  freeze a running instance into an image
#
# The installer never branches on the backend's *name*: it calls a verb. What a
# backend cannot do it does the long way round - Incus, for instance, has no
# native snapshot for a workspace whose home is a host directory, so it uses the
# same commit + home-archive path as every other backend. `ENGINE` holds the active
# backend's name and doubles as the on-disk state key; `ENGINE_BIN` is the
# command it drives.
# ---------------------------------------------------------------------------

ENGINE="${ENGINE:-}"
ENGINE_BIN="${ENGINE_BIN:-}"
BACKEND_REQUEST="${BACKEND_REQUEST:-auto}"
BACKEND_DIR="${BACKEND_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# backend_names prints every backend this installer knows, in preference order.
# Incus leads: a workspace in a system container is the isolation this project
# is for. It only counts as *present* once backend-incus.sh exists, so an
# incomplete tree never advertises a backend it cannot drive.
backend_names() {
  local name
  for name in incus podman docker; do
    if [[ "$name" == "incus" ]]; then
      [[ -r "${BACKEND_DIR}/backend-incus.sh" ]] || continue
    fi
    command -v "$name" >/dev/null 2>&1 || continue
    printf '%s\n' "$name"
  done
  # A caller assigns this: `names="$(backend_names)"`. Without an explicit 0 the
  # function would inherit the status of the last command - a `command -v` that
  # found nothing for the last backend in the list - and the assignment would
  # then fail under `set -e`, killing every dry run on a host that has, say,
  # podman but not docker. Silence, exit 1, no message: exactly the failure that
  # took a bisect to find.
  return 0
}

# backend_ready NAME tells whether the backend can actually do work right now.
# A binary on PATH is not enough: an installed-but-uninitialised Incus answers
# every verb with an error, and silently picking it would turn "run a workspace"
# into a wall of failures. Read-only and never fatal.
backend_ready() {
  local name="${1:-}"
  command -v "$name" >/dev/null 2>&1 || return 1
  case "$name" in
    incus) "${name}" info >/dev/null 2>&1 || return 1 ;;
    *)     "${name}" --version >/dev/null 2>&1 || return 1 ;;
  esac
  return 0
}

# backend_not_ready_hint NAME prints the one action that would make the backend
# usable. Criterion for a good hint: the user can paste it. Nothing here is run
# by the installer - preparing the host is the user's call (see doctor).
backend_not_ready_hint() {
  case "${1:-}" in
    incus) printf '%s\n' 'sudo systemctl enable --now incus.socket && sudo incus admin init --minimal' ;;
    *)     printf '%s\n' "the ${1} daemon is not answering" ;;
  esac
}

backend_load() {
  local name="${1:-}" file
  file="${BACKEND_DIR}/backend-${name}.sh"
  if [[ ! -r "$file" ]]; then
    die_k err_no_backend_impl "${name}" "${file}"
  fi
  # shellcheck source=/dev/null
  source "$file"
}

# resolve_engine [auto|NAME]: pick a backend, load it and announce it.
resolve_engine() {
  local wanted="${1:-auto}" names pick="" hint=""
  names="$(backend_names)"
  if [[ -z "$names" ]]; then
    die_k need_engine
  fi
  if [[ "$wanted" == "auto" ]]; then
    while IFS= read -r candidate; do
      if backend_ready "$candidate"; then pick="$candidate"; break; fi
    done <<<"$names"
    if [[ -z "$pick" ]]; then
      # Every backend present is installed but not usable. Say which one and
      # what would fix it instead of dying on a bare "no engine".
      pick="$(printf '%s\n' "$names" | head -n 1)"
      hint="$(backend_not_ready_hint "$pick")"
      die_k err_backend_not_ready "${pick}" "${hint}"
    fi
    # More than one is present: the choice is ours, so say which one it is and
    # how to overrule it (a host with incus *and* podman is the normal case).
    if [[ "$(printf '%s\n' "$names" | grep -c .)" -gt 1 ]]; then
      warn_k warn_both_engines "$(printf '%s\n' "$names" | paste -sd, -)" "$pick"
    fi
    ENGINE="$pick"
  else
    if ! printf '%s\n' "$names" | grep -qx "$wanted"; then
      die_k err_backend_missing "${wanted}" "${wanted}"
    fi
    if ! backend_ready "$wanted"; then
      die_k err_backend_not_ready "${wanted}" "$(backend_not_ready_hint "$wanted")"
    fi
    ENGINE="$wanted"
  fi
  ENGINE_BIN="$ENGINE"
  backend_load "$ENGINE"
  msg_k engine_line "${ENGINE}" "$(eng_version)"
}

# use_engine NAME switches to the backend recorded for an existing instance.
# An instance's backend is not a preference: it is where the instance lives.
use_engine() {
  local name="${1:-}"
  [[ -z "$name" ]] && return 0
  if ! command -v "$name" >/dev/null 2>&1; then
    die_k err_engine_required "${name}"
  fi
  ENGINE="$name"
  ENGINE_BIN="$name"
  backend_load "$ENGINE"
}

# run_engine is the raw, dry-run aware escape hatch. Backends that drive a
# container CLI use it; nothing outside a backend file should.
run_engine() {
  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    printf 'dry-run: %s' "$ENGINE_BIN"
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$ENGINE_BIN" "$@"
}

# --- shared helpers --------------------------------------------------------

# eng_host_port NAME PORT prints the host address a published container port is
# bound to, or nothing when the port is not published. Used by ./install.sh web
# and by doctor, so a container created before the web support existed still
# reports the address the backend actually assigned.
eng_host_port() {
  local name="$1" port="$2" out=""
  # a container with no published port makes the engine exit non-zero; keep the
  # lookup non-fatal under errexit and answer with an empty string instead
  out="$("$ENGINE_BIN" port "$name" "${port}/tcp" 2>/dev/null)" || true
  printf '%s\n' "${out%%$'\n'*}"
}

# engine_mount_suffix prints the SELinux relabel suffix a host bind mount needs.
# The container CLIs accept ":z"; a backend that labels its own mounts overrides
# this (Incus does), and a backend with no host bind mounts ignores it.
engine_mount_suffix() { printf ':z'; }

# detect_engines is the historical name for "which backends are present"; doctor
# and the tests still ask for it.
detect_engines() {
  backend_names
}
