#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Incus backend: a workspace is an instance inside an Incus daemon that the
# user runs on their own machine - no root, no kernel modules, no hand-written
# LXC config, no networking setup of our own.
#
# Incus is not a container CLI: instances, images, storage and networks are
# objects owned by a daemon, so this file implements the verbs itself instead of
# going through backend-container-cli.sh. The mapping is:
#
#   instance       incus instance (a system container; `incus launch`)
#   home "volume"  an ordinary host directory, bind-mounted as a disk device.
#                  Deliberately *not* an Incus storage volume: rollback, fork
#                  and backup then use the tools the user already has, the data
#                  stays inspectable, and an 8.5 GB image is never copied
#                  because the workspace needs a new incarnation.
#   workspace      no host directory is mounted: the agent works in the
#                  instance's own /home/agent, which is the home device below
#   web port       a proxy device listening on 127.0.0.1 only
#   image          our OCI image, exported to a rootfs tarball with podman or
#                  docker and imported into Incus once per image id
#   labels         incus config keys `user.<label>` (see LABEL_KEY/LABEL_NS)
#   snapshot       the commit + home-archive path every other backend uses too:
#                  instance snapshot would not contain the host-directory home,
#                  so advertising native snapshots here would be a lie.
#
# The home device is added with shift=true: in an unprivileged Incus instance
# the agent's uid is offset (1000000, not 1000), so an unshifted mount of a
# host directory is read-only for the very user that has to work in it.
# shift=true uses an idmapped mount instead (btrfs and modern kernels support
# it), which is what makes /home/agent writable for the agent.
#
# Requires a one-time root step on the host - `sudo systemctl enable --now
# incus.socket && sudo incus admin init --minimal` - and nothing else.
# ---------------------------------------------------------------------------


: "${ENGINE_BIN:?the Incus backend needs ENGINE_BIN (incus)}"

# Host-side state. The homes are the only thing on the host that holds agent
# data, so they live under the user's data directory rather than inside a
# daemon-owned pool: `ls`, `tar`, `cp` and the user's backup tooling all work on
# them, and no daemon has to be running to read them.
INCUS_STATE_DIR="${INCUS_STATE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/agent-workspace/incus}"
INCUS_HOMES_DIR="${INCUS_HOMES_DIR:-${INCUS_STATE_DIR}/homes}"
INCUS_IMAGES_DIR="${INCUS_IMAGES_DIR:-${INCUS_STATE_DIR}/images}"
INCUS_HOME_DEVICE="${INCUS_HOME_DEVICE:-home}"
INCUS_WEB_DEVICE="${INCUS_WEB_DEVICE:-web}"

# dry-run aware version of run_engine for the *other* CLI (podman or docker),
# which this backend uses only to get our OCI image out of a registry.
INCUS_IMAGE_HELPER="${INCUS_IMAGE_HELPER:-}"

_incus_helper_run() {
  local helper="$1"; shift
  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    printf 'dry-run: %s' "$helper"
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$helper" "$@"
}

# Host-side work (the homes, the image export) happens with the tools on this
# machine, not through the daemon, so it has to respect --dry-run itself.
# What it prints is the command, not a sentence - same shape as run_engine, and
# no English prose outside the catalogue.
_incus_dry() {
  [[ "${DRY_RUN:-0}" -eq 1 ]] || return 1
  printf 'dry-run:'
  printf ' %q' "$@"
  printf '\n'
  return 0
}

# --- images ----------------------------------------------------------------
#
# Incus cannot pull an OCI image, and our image is a *system* container (systemd
# as PID 1, first boot provisioning) - not the application container that
# Incus's own OCI remote would run. So the image is exported once with the
# container CLI that is already on the host and imported as a plain image.

_incus_image_helper() {
  if [[ -n "$INCUS_IMAGE_HELPER" ]]; then
    printf '%s\n' "$INCUS_IMAGE_HELPER"
    return 0
  fi
  local candidate
  for candidate in podman docker; do
    if command -v "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

# An Incus image alias is a flat name, so the image reference is folded into
# one. The alias is stable for a given reference; what changed *under* a moving
# tag (latest) is caught with the stamp file below, which records the container
# image id the alias was imported from.
_incus_alias() {
  local ref="$1" folded
  folded="$(printf '%s' "$ref" | sed 's/[^A-Za-z0-9_.-]/_/g')"
  printf 'aw-%s\n' "${folded:0:70}"
}

_incus_stamp_file() {
  printf '%s/%s.id\n' "$INCUS_IMAGES_DIR" "$(_incus_alias "$1")"
}

# The id of the container image the imported rootfs came from, as recorded at
# import time. Empty when the image was never imported.
_incus_imported_id() {
  local file
  file="$(_incus_stamp_file "$1")"
  [[ -r "$file" ]] || return 0
  head -n 1 "$file" 2>/dev/null || true
}

_incus_image_present() {
  local alias
  alias="$(_incus_alias "$1")"
  "$ENGINE_BIN" image alias list --format csv -c n 2>/dev/null | grep -qx -- "$alias"
}

eng_image_exists() {
  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    run_engine image alias list --format csv -c n
    return 0
  fi
  _incus_image_present "$1"
}

# eng_pull IMAGE: make IMAGE available to Incus, importing it when what is
# imported is not the image the host currently has.
eng_pull() {
  local image="$1" helper alias current recorded
  alias="$(_incus_alias "$image")"
  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    helper="$(_incus_image_helper 2>/dev/null || printf 'podman')"
    _incus_helper_run "$helper" pull "$image"
    _incus_dry "$ENGINE_BIN" image import metadata.tar rootfs.tar.xz --alias "$alias"
    return 0
  fi

  helper="$(_incus_image_helper)" || die_k err_incus_helper "$image"
  command -v xz >/dev/null 2>&1 || die_k err_incus_helper "$image"

  _incus_helper_run "$helper" pull "$image" >&2
  current="$("$helper" image inspect --format '{{.Id}}' "$image" 2>/dev/null || true)"
  [[ -n "$current" ]] || die_k err_incus_image_missing "$image"

  if _incus_image_present "$image"; then
    recorded="$(_incus_imported_id "$image")"
    if [[ "$recorded" == "$current" ]]; then
      return 0
    fi
    # The tag moved: the imported rootfs is stale. Drop it and import again.
    "$ENGINE_BIN" image delete "$alias" >/dev/null 2>&1 || true
  fi

  # A rootfs export is large; the working files are removed on every exit path
  # (no trap: RETURN traps only run for traced functions, so a trap here would
  # silently leak gigabytes when the shell is not running with -T).
  local work ctr rootfs metadata
  work="$(mktemp -d "${TMPDIR:-/tmp}/aw-incus-image.XXXXXX")"
  rootfs="${work}/rootfs.tar.xz"
  metadata="${work}/metadata.tar"

  if ! ctr="$("$helper" create "$image" 2>/dev/null)"; then
    rm -rf -- "$work"
    die_k err_incus_image_missing "$image"
  fi
  if ! "$helper" export "$ctr" | xz -T0 -1 >"$rootfs"; then
    rm -rf -- "$work"
    # shellcheck disable=SC2086
    "$helper" rm --force $ctr >/dev/null 2>&1 || true
    die_k err_incus_image_missing "$image"
  fi
  "$helper" rm --force "$ctr" >/dev/null 2>&1 || true

  if ! mkdir -p "${INCUS_IMAGES_DIR}" ||
    ! printf 'architecture: %s\ncreation_date: %s\nproperties:\n  description: %s\n  os: linux\n' \
      "$(uname -m)" "$(date +%s)" "agent-workspace ${image}" >"${work}/metadata.yaml" ||
    ! tar -C "$work" -cf "$metadata" metadata.yaml; then
    rm -rf -- "$work"
    die_k err_incus_image_missing "$image"
  fi

  if ! "$ENGINE_BIN" image import "$metadata" "$rootfs" --alias "$alias"; then
    rm -rf -- "$work"
    die_k err_incus_image_missing "$image"
  fi
  rm -rf -- "$work"

  printf '%s\n' "$current" >"$(_incus_stamp_file "$image")"
  chmod 0644 "$(_incus_stamp_file "$image")"
}

# eng_image_remove IMAGE
eng_image_remove() {
  run_engine image delete "$(_incus_alias "$1")" >/dev/null 2>&1 || true
  rm -f -- "$(_incus_stamp_file "$1")" 2>/dev/null || true
}

# Display-only, like the container-CLI backends: a missing image must not abort
# the caller, so every failure degrades to an empty string.
eng_image_id() {
  local out
  out="$("$ENGINE_BIN" image list "$(_incus_alias "$1")" --format csv -c f 2>/dev/null | cut -c1-12)" || true
  printf '%s\n' "$out"
}

eng_image_created() {
  local out
  out="$("$ENGINE_BIN" image list "$(_incus_alias "$1")" --format csv -c u 2>/dev/null)" || true
  printf '%s\n' "$out"
}

eng_version() {
  local out
  out="$("$ENGINE_BIN" --version 2>/dev/null | head -n 1)" || true
  printf '%s\n' "$out"
}

# --- instances -------------------------------------------------------------

eng_container_exists() { "$ENGINE_BIN" info "$1" >/dev/null 2>&1; }

eng_container_running() {
  local state
  state="$("$ENGINE_BIN" list "$1" --format csv -c s 2>/dev/null || true)"
  [[ "${state^^}" == "RUNNING" ]]
}

eng_container_status() {
  local state
  state="$("$ENGINE_BIN" list "$1" --format csv -c s 2>/dev/null || true)"
  if [[ -z "$state" ]]; then
    printf 'missing\n'
  else
    printf '%s\n' "${state,,}"
  fi
}

# The image the instance was created from: recorded as our own key at creation
# time, because Incus itself only keeps a `volatile.base_image` fingerprint that
# changes meaning once the image is aliased away.
eng_container_image() {
  local out
  out="$("$ENGINE_BIN" config get "$1" user.aw.image 2>/dev/null || true)"
  printf '%s\n' "$out"
}

eng_labeled_containers() {
  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    run_engine list --format csv -c n,t
    return 0
  fi
  local raw name type out=""
  raw="$("$ENGINE_BIN" list --format csv -c n,t 2>/dev/null || true)"
  while IFS=, read -r name type; do
    [[ -n "$name" ]] || continue
    [[ "$type" == "CONTAINER" || "$type" == "VIRTUAL-MACHINE" ]] || continue
    if [[ "$("$ENGINE_BIN" config get "$name" "user.${LABEL_KEY}" 2>/dev/null || true)" == "$LABEL_VALUE" ]]; then
      out+="${name}"$'\n'
    fi
  done <<<"$raw"
  printf '%s' "$out"
}

eng_stop()  { run_engine stop "$1" >/dev/null 2>&1 || true; }
eng_start() { run_engine start "$1"; }
eng_remove() { run_engine delete --force "$1"; }

# incus has no `port`: the published address lives in the proxy device.
eng_host_port() {
  local name="$1" port="$2" listen=""
  listen="$("$ENGINE_BIN" config device get "$name" "$INCUS_WEB_DEVICE" listen 2>/dev/null || true)"
  listen="${listen#tcp:}"
  # Only the port the caller asked about, and only when it is a host address.
  if [[ "$listen" == *":${port}" ]]; then
    printf '%s\n' "$listen"
  fi
}

# Incus labels its own mounts (and idmapped mounts must not carry :z).
engine_mount_suffix() { printf ''; }

# --- the agent's home ------------------------------------------------------

_incus_home_dir() { printf '%s/%s\n' "$INCUS_HOMES_DIR" "$1"; }

eng_volume_exists() { [[ -d "$(_incus_home_dir "$1")" ]]; }

eng_volume_create() {
  _incus_dry install -d -m 0700 -- "$(_incus_home_dir "$1")" && return 0
  install -d -m 0700 -- "$(_incus_home_dir "$1")"
}

eng_volume_remove() {
  local name="$1" dir
  # Never let an empty or escaped name turn into `rm -rf` on something else.
  [[ -n "$name" && "$name" != */* && "$name" != "." && "$name" != ".." ]] || return 0
  dir="$(_incus_home_dir "$name")"
  [[ "$dir" == "${INCUS_HOMES_DIR}/"* ]] || return 0
  _incus_dry rm -rf -- "$dir" && return 0
  rm -rf -- "$dir"
}

# eng_volume_archive VOLUME DIR IMAGE -> DIR/home.tar.gz
eng_volume_archive() {
  local volume="$1" dir="$2" archive
  archive="${dir}/home.tar.gz"
  _incus_dry tar czf "$archive" -C "$(_incus_home_dir "$volume")" . && return 0
  mkdir -p -- "$dir"
  tar czf "$archive" -C "$(_incus_home_dir "$volume")" .
}

# eng_volume_export_path VOLUME REL OUTDIR IMAGE
#
# The Incus home is a host-side directory the daemon is not needed to read, so
# a single path can be tarred straight out of it. REL is relative to the home
# root and has already been checked by the caller not to escape it.
eng_volume_export_path() {
  local volume="$1" rel="$2" outdir="$3" image="$4"
  _incus_dry tar czf "$outdir/rescue.tar.gz" -C "$(_incus_home_dir "$volume")" -- "$rel" && return 0
  tar czf "$outdir/rescue.tar.gz" -C "$(_incus_home_dir "$volume")" -- "$rel"
}

# eng_volume_restore_archive VOLUME ARCHIVE IMAGE
eng_volume_restore_archive() {
  local volume="$1" archive="$2" home
  home="$(_incus_home_dir "$volume")"
  _incus_dry tar xzf "$archive" -C "$home" && return 0
  install -d -m 0700 -- "$home"
  tar xzf "$archive" -C "$home"
}

# eng_volume_clone SRC DST IMAGE - the fork path, and the reason the home is a
# plain directory: on btrfs this is a reflink copy, not 8 GB of I/O.
eng_volume_clone() {
  local src="$1" dst="$2" from to
  from="$(_incus_home_dir "$src")"
  to="$(_incus_home_dir "$dst")"
  _incus_dry cp -a -- "$from/." "$to/" && return 0
  eng_volume_exists "$dst" || install -d -m 0700 -- "$to"
  cp -a -- "$from/." "$to/"
}

# --- environment -----------------------------------------------------------
#
# Our image takes its credentials from the process environment, so the instance
# has to carry them. Two rules shaped this: the value never lands in this
# process's command line (it is piped to `incus config set` on stdin), and what
# the daemon stores is read back and compared - a daemon that answers "ok" to a
# value it did not store would otherwise hand the agent a workspace with no
# credentials and no error.

_incus_env_set() {
  local name="$1" key="$2" value="$3" got
  _incus_dry "$ENGINE_BIN" config set "$name" "environment.${key}" '<value from stdin>' && return 0
  printf '%s' "$value" | "$ENGINE_BIN" config set "$name" "environment.${key}" - >/dev/null 2>&1 \
    || die_k err_incus_env "$key"
  got="$("$ENGINE_BIN" config get "$name" "environment.${key}" 2>/dev/null || true)"
  [[ "$got" == "$value" ]] || die_k err_incus_env_verify "$key"
}

_incus_env_from_file() {
  local name="$1" file="$2" line key value
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    line="${line#export }"
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    # shellcheck disable=SC2086
    value="$(printf '%s' "$value" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")"
    _incus_env_set "$name" "$key" "$value"
  done <"$file"
}

# --- creation --------------------------------------------------------------

_incus_labels() {
  local name="$1" agent="$2" mode="$3" image="$4"
  # Two namespaces on purpose: LABEL_* is what `labels`/prune look for on any
  # backend, and `user.aw.*` is where this backend keeps its own bookkeeping.
  # `config set` takes the key and the value as two arguments - the `key=value`
  # spelling belongs to `config device add` and is not accepted here.
  run_engine config set "$name" "user.${LABEL_KEY}" "${LABEL_VALUE}"
  run_engine config set "$name" "user.${LABEL_NS}.agent" "$agent"
  run_engine config set "$name" "user.${LABEL_NS}.mode" "$mode"
  run_engine config set "$name" "user.aw.image" "$image"
}

_incus_devices() {
  local name="$1" home="$2" web_port="$3"
  run_engine config device add "$name" "$INCUS_HOME_DEVICE" disk \
    source="$home" path="/home/${AGENT_USER}" shift=true
  if [[ -n "$web_port" ]]; then
    run_engine config device add "$name" "$INCUS_WEB_DEVICE" proxy \
      "listen=tcp:127.0.0.1:${web_port}" "connect=tcp:127.0.0.1:${WEB_CONTAINER_PORT:-3080}"
  fi
}

_incus_instance_ready() {
  local name="$1" image="$2" agent="$3" mode="$4" home="$5" env_file="$6" web_port="$7"
  _incus_labels "$name" "$agent" "$mode" "$image"
  _incus_devices "$name" "$home" "$web_port"
  _incus_env_set "$name" AGENT_WORKSPACE_AGENT "$agent"
  _incus_env_from_file "$name" "$env_file"
}

# eng_create_persistent NAME IMAGE VOLUME ENV_FILE WEB_PORT AGENT
#
# No workspace disk device: an instance's own /home/agent is the workspace, and
# the home device is the only host-side thing it mounts.
eng_create_persistent() {
  local name="$1" image="$2" volume="$3" env_file="$4" web_port="$5" agent="$6"
  local home
  if [[ "${DRY_RUN:-0}" -eq 0 ]]; then
    eng_image_exists "$image" || die_k err_incus_image_missing "$image"
    eng_volume_exists "$volume" || eng_volume_create "$volume"
  fi
  home="$(_incus_home_dir "$volume")"
  run_engine init "$(_incus_alias "$image")" "$name"
  _incus_instance_ready "$name" "$image" "$agent" persistent "$home" "$env_file" "$web_port"
  run_engine start "$name"
}

# eng_create_ephemeral NAME IMAGE ENV_FILE AGENT COMMAND
#
# The container CLIs pass COMMAND as the container's own argv (`run --rm`); with
# an instance that has to boot first, the equivalent is: start it, run COMMAND
# inside it with the agent's credentials, then delete the instance. No disk
# device is added: a one-shot run writes nothing that is meant to outlive it.
eng_create_ephemeral() {
  local name="$1" image="$2" env_file="$3" agent="$4" command="$5"
  local status=0
  if [[ "${DRY_RUN:-0}" -eq 0 ]]; then
    eng_image_exists "$image" || die_k err_incus_image_missing "$image"
  fi
  run_engine init "$(_incus_alias "$image")" "$name"
  _incus_labels "$name" "$agent" ephemeral "$image"
  run_engine config set "$name" environment.HOME "/home/${agent}"
  _incus_env_set "$name" AGENT_WORKSPACE_AGENT "$agent"
  _incus_env_from_file "$name" "$env_file"
  run_engine start "$name"
  if [[ "${DRY_RUN:-0}" -eq 0 ]]; then
    "$ENGINE_BIN" exec "$name" --user "$agent" -- /bin/bash -c "$command" || status=$?
    "$ENGINE_BIN" delete --force "$name" >/dev/null 2>&1 || true
  fi
  return "$status"
}

# --- running things inside the instance ------------------------------------

eng_exec() {
  local name="$1"; shift
  run_engine exec "$name" -- "$@"
}

# eng_exec_root NAME CMD...: an interactive root shell inside the instance, for
# `rescue` when the agent account is locked or the configuration is broken.
# Incus already runs `exec` as root unless --user says otherwise; spelling it
# keeps the verb's contract identical across backends.
eng_exec_root() {
  local name="$1"; shift
  run_engine exec "$name" --user root -- "$@"
}

eng_exec_test() {
  local name="$1"; shift
  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    run_engine exec "$name" -- "$@"
    return 0
  fi
  "$ENGINE_BIN" exec "$name" -- "$@" >/dev/null 2>&1
}

eng_exec_capture() {
  local name="$1"; shift
  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    run_engine exec "$name" -- "$@"
    return 0
  fi
  "$ENGINE_BIN" exec "$name" -- "$@" 2>/dev/null || true
}

# eng_exec_background NAME USER SHELL_COMMAND
#
# `incus exec` has no --detach, and the web UI has to outlive the exec session
# that started it, so the command is started in its own session (setsid) with
# no terminal attached; the command itself already writes its own log file.
eng_exec_background() {
  local name="$1" user="$2" command="$3"
  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    run_engine exec "$name" --user "$user" --env "HOME=/home/${user}" -- /bin/bash -c "setsid --fork /bin/bash -c <command>"
    return 0
  fi
  "$ENGINE_BIN" exec "$name" --user "$user" --env "HOME=/home/${user}" -- \
    /bin/bash -c "setsid --fork /bin/bash -c $(printf '%q' "$command") </dev/null >/dev/null 2>&1"
}

eng_logs() {
  local name="$1" tail="${2:-50}" follow="${3:-0}"
  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    run_engine console --show-log "$name"
    return 0
  fi
  if [[ "$follow" -eq 1 ]] && eng_container_running "$name"; then
    "$ENGINE_BIN" exec "$name" -- journalctl --no-pager -n "$tail" --follow || true
    return 0
  fi
  "$ENGINE_BIN" console --show-log "$name" 2>/dev/null | tail -n "$tail" || true
}

# eng_image_run IMAGE CMD...: one-shot command out of the image. An instance has
# to boot for this, which is slower than `docker run` - it is used once, to read
# the image's own agent catalogue.
eng_image_run() {
  local image="$1"; shift
  local name="aw-once-$$"
  run_engine init "$(_incus_alias "$image")" "$name"
  run_engine start "$name"
  run_engine exec "$name" -- "$@"
  run_engine delete --force "$name" >/dev/null 2>&1 || true
}

# eng_commit NAME REF: freeze the running instance into an image. The installer's
# snapshot path then archives the home directory next to it, which is why the
# two together are a complete snapshot of a workspace.
eng_commit() {
  run_engine publish "$1" --alias "$2"
}
