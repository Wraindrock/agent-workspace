#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Engine abstraction: one interface over podman and docker.
#
# Everything this installer does to a container goes through run_engine(), so
# the two engines differ only in the flags assembled here.
# ---------------------------------------------------------------------------

ENGINE="${ENGINE:-}"
ENGINE_BIN="${ENGINE_BIN:-}"

detect_engines() {
  local candidate
  for candidate in podman docker; do
    if command -v "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
    fi
  done
}

resolve_engine() {
  local wanted="${1:-auto}" available count
  available="$(detect_engines)"
  if [[ -z "$available" ]]; then
    die "neither podman nor docker is installed; install one of them first"
  fi
  if [[ "$wanted" == "auto" ]]; then
    ENGINE="$(printf '%s\n' "$available" | head -n 1)"
    count="$(printf '%s\n' "$available" | wc -l)"
    if [[ "$count" -gt 1 ]]; then
      warn "both podman and docker are installed; using ${ENGINE} (override with --engine)"
    fi
  else
    if ! printf '%s\n' "$available" | grep -qx "$wanted"; then
      die "--engine ${wanted} was requested but ${wanted} is not installed"
    fi
    ENGINE="$wanted"
  fi
  ENGINE_BIN="$ENGINE"
}

# use_engine switches to the engine recorded for an existing container.
use_engine() {
  local name="${1:-}"
  [[ -z "$name" ]] && return 0
  if ! command -v "$name" >/dev/null 2>&1; then
    die "container engine ${name} is required for this container but is not installed"
  fi
  ENGINE="$name"
  ENGINE_BIN="$name"
}

run_engine() {
  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    printf 'dry-run: %s' "$ENGINE_BIN"
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$ENGINE_BIN" "$@"
}

# --- read-only queries -----------------------------------------------------

eng_version()      { "$ENGINE_BIN" --version 2>/dev/null | head -n 1; }
eng_container_exists() { "$ENGINE_BIN" container inspect "$1" >/dev/null 2>&1; }

eng_container_running() {
  local state
  state="$("$ENGINE_BIN" inspect --format '{{.State.Running}}' "$1" 2>/dev/null || true)"
  [[ "$state" == "true" ]]
}

eng_container_status() {
  "$ENGINE_BIN" inspect --format '{{.State.Status}}' "$1" 2>/dev/null || printf 'missing'
}

eng_container_image() {
  "$ENGINE_BIN" inspect --format '{{.Config.Image}}' "$1" 2>/dev/null || true
}

eng_volume_exists() { "$ENGINE_BIN" volume inspect "$1" >/dev/null 2>&1; }
eng_image_exists()  { "$ENGINE_BIN" image inspect "$1" >/dev/null 2>&1; }

eng_labeled_containers() {
  "$ENGINE_BIN" ps --all --filter "label=${LABEL_KEY}=${LABEL_VALUE}" --format '{{.Names}}' 2>/dev/null || true
}

# --- mutations -------------------------------------------------------------

eng_pull()        { run_engine pull "$@"; }
eng_stop()        { run_engine stop "$1" >/dev/null 2>&1 || true; }
eng_start()       { run_engine start "$1"; }
eng_remove()      { run_engine rm --force "$1"; }
eng_volume_create() { run_engine volume create "$1"; }
eng_volume_remove() { run_engine volume rm --force "$1" || true; }
eng_exec()        { local name="$1"; shift; run_engine exec --interactive --tty "$name" "$@"; }

eng_commit() {
  # podman can pin the format; docker's commit has no such flag.
  if [[ "$ENGINE" == "podman" ]]; then
    run_engine commit --format oci "$1" "$2"
  else
    run_engine commit "$1" "$2"
  fi
}

# --- engine specific run flags ---------------------------------------------

# Persistent containers run the image as a complete Linux system: systemd is
# PID 1 and the agent is reached with "exec".
engine_run_flags() {
  if [[ "$ENGINE" == "podman" ]]; then
    printf '%s\n' --detach --systemd=always --restart unless-stopped
  else
    # Docker needs the cgroup namespace and mounts to boot systemd.
    printf '%s\n' --detach --restart unless-stopped --privileged --cgroupns=host
    printf '%s\n' --volume /sys/fs/cgroup:/sys/fs/cgroup:rw
    printf '%s\n' --tmpfs /run --tmpfs /tmp
  fi
}

# SELinux hosts need the relabel suffix; podman and docker both accept it.
engine_mount_suffix() {
  printf ':z'
}
