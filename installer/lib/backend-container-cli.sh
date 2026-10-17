#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Shared implementation of the backend verbs for the container CLIs that speak
# the docker command language: podman and docker. backend-podman.sh and
# backend-docker.sh set their identity and their flags, then source this file,
# so the two differ only where they really differ (how systemd boots, how commit
# names its format).
#
# Not a backend on its own: it is never loaded on its own.
# ---------------------------------------------------------------------------


# The CLI this backend drives (podman or docker), set by the loader.
: "${ENGINE_BIN:?the container CLI backend needs ENGINE_BIN}"

eng_version() {
  local out
  out="$("$ENGINE_BIN" --version 2>/dev/null | head -n 1)" || true
  printf '%s\n' "$out"
}

# --- read-only queries -----------------------------------------------------

eng_container_exists()  { "$ENGINE_BIN" container inspect "$1" >/dev/null 2>&1; }

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

# Which local copy is about to be used, and when it was built. Display-only
# queries: a missing image must not abort the caller (these run under
# `set -e`), so a failure degrades to an empty string instead of an exit status.
eng_image_id() {
  local out
  out="$("$ENGINE_BIN" image inspect --format '{{.Id}}' "$1" 2>/dev/null | sed 's/^sha256://' | cut -c1-12)" || true
  printf '%s\n' "$out"
}

eng_image_created() {
  local out
  out="$("$ENGINE_BIN" image inspect --format '{{.Created}}' "$1" 2>/dev/null | sed 's/\.[0-9]\{1,\} / /')" || true
  printf '%s\n' "$out"
}

eng_labeled_containers() {
  "$ENGINE_BIN" ps --all --filter "label=${LABEL_KEY}=${LABEL_VALUE}" --format '{{.Names}}' 2>/dev/null || true
}

# --- mutations -------------------------------------------------------------

eng_pull()          { run_engine pull "$@"; }
eng_image_remove()  { run_engine rmi "$1"; }
eng_stop()          { run_engine stop "$1" >/dev/null 2>&1 || true; }
eng_start()         { run_engine start "$1"; }
eng_remove()        { run_engine rm --force "$1"; }
eng_volume_create() { run_engine volume create "$1"; }
eng_volume_remove() { run_engine volume rm --force "$1" || true; }
eng_exec()          { local name="$1"; shift; run_engine exec --interactive --tty "$name" "$@"; }

# eng_exec_root NAME CMD...: an interactive command as root inside the instance.
# Used by `rescue` when the agent account itself is locked; the backend owns the
# spelling (`--user root` here, `--user root` on incus) so commands.sh does not
# hard-code one engine's flags.
eng_exec_root()     { local name="$1"; shift; run_engine exec --interactive --tty --user root "$name" "$@"; }

# eng_exec_test NAME CMD...: run it, keep the exit status, drop the output.
eng_exec_test() {
  local name="$1"; shift
  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then run_engine exec "$name" "$@"; return 0; fi
  "$ENGINE_BIN" exec "$name" "$@" >/dev/null 2>&1
}

# eng_exec_capture NAME CMD...: print what it prints; a failure is empty output,
# not an error, because every caller treats "no output" as "not ready yet".
eng_exec_capture() {
  local name="$1"; shift
  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then run_engine exec "$name" "$@"; return 0; fi
  "$ENGINE_BIN" exec "$name" "$@" 2>/dev/null || true
}

# eng_exec_background NAME USER SHELL_COMMAND: start SHELL_COMMAND inside the
# instance as USER and return without waiting for it. This is how the agent's
# web UI is launched and how its log file gets written.
eng_exec_background() {
  local name="$1" user="$2" command="$3"
  run_engine exec --detach --user "$user" --env "HOME=/home/${user}" "$name" /bin/bash -c "$command"
}

eng_logs() {
  local name="$1" tail="${2:-50}" follow="${3:-0}"
  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then run_engine logs --tail "$tail" "$name"; return 0; fi
  if [[ "$follow" -eq 1 ]]; then
    "$ENGINE_BIN" logs --tail "$tail" --follow "$name"
  else
    "$ENGINE_BIN" logs --tail "$tail" "$name"
  fi
}

# eng_image_run IMAGE CMD...: one-shot command out of the image, nothing left
# behind. Used to read the image's agent catalogue.
eng_image_run() {
  local image="$1"; shift
  run_engine run --rm --entrypoint "$1" "$image" "${@:2}"
}

eng_commit() {
  # commands.sh runs this only when the backend advertises the commit path.
  run_engine commit "$1" "$2"
}

# --- the agent's home volume ----------------------------------------------
#
# The home volume is a named volume, and every backend has to be able to
# archive it, put an archive back, and copy it for a fork. The container CLIs
# have no volume export worth relying on across versions, so the work happens in
# a throwaway container from IMAGE (the snapshot's image, or the running one),
# which is what the installer did before the backends existed.

# eng_volume_archive VOLUME DIR IMAGE -> DIR/home.tar.gz
eng_volume_archive() {
  local volume="$1" dir="$2" image="$3"
  run_engine run --rm --entrypoint /usr/bin/tar --volume "${volume}:/data:ro" \
    --volume "${dir}:/backup$(engine_mount_suffix)" "$image" czf /backup/home.tar.gz -C /data .
}

# eng_volume_export_path VOLUME REL OUTDIR IMAGE
#
# Copy one path (relative to the volume root) out to OUTDIR/rescue.tar.gz, so
# `rescue --copy` reads a single file or directory instead of a whole home.
eng_volume_export_path() {
  local volume="$1" rel="$2" outdir="$3" image="$4"
  run_engine run --rm --entrypoint /usr/bin/tar \
    --volume "${volume}:/data:ro" \
    --volume "${outdir}:/backup$(engine_mount_suffix)" \
    "$image" czf /backup/rescue.tar.gz -C /data "$rel"
}

# eng_volume_restore_archive VOLUME ARCHIVE IMAGE
eng_volume_restore_archive() {
  local volume="$1" archive="$2" image="$3" dir
  dir="$(dirname "$archive")"
  eng_volume_exists "$volume" || eng_volume_create "$volume" >/dev/null
  run_engine run --rm --entrypoint /usr/bin/tar --volume "${volume}:/data" \
    --volume "${dir}:/backup$(engine_mount_suffix)" "$image" xzf "/backup/$(basename "$archive")" -C /data
}

# eng_volume_clone SRC DST IMAGE
eng_volume_clone() {
  local src="$1" dst="$2" image="$3"
  eng_volume_exists "$dst" || eng_volume_create "$dst" >/dev/null
  run_engine run --rm --entrypoint /bin/bash --volume "${src}:/from:ro" --volume "${dst}:/to" \
    "$image" -c 'cd /from && tar cf - . | tar xf - -C /to'
}

# --- creation --------------------------------------------------------------

# eng_create_persistent NAME IMAGE VOLUME ENV_FILE WEB_PORT AGENT
#
# The long-lived workspace: systemd is PID 1, the agent's home is a named volume
# (so rollback/recover/upgrade rebuild the container around it), and the web UI
# is published on the host loopback only. No host directory is mounted: the
# agent works in /home/agent, which is the volume itself.
eng_create_persistent() {
  local name="$1" image="$2" volume="$3" env_file="$4" web_port="$5" agent="$6"
  local -a args=(run --name "$name" --hostname "$name")
  local flag
  while IFS= read -r flag; do args+=("$flag"); done < <(eng_run_flags)
  args+=(--label "${LABEL_KEY}=${LABEL_VALUE}")
  args+=(--label "${LABEL_NS}.agent=${agent}")
  args+=(--label "${LABEL_NS}.mode=persistent")
  args+=(--volume "${volume}:/home/${AGENT_USER}")
  args+=(--workdir "/home/${AGENT_USER}")
  args+=(--env "AGENT_WORKSPACE_AGENT=${agent}")
  [[ -f "$env_file" ]] && args+=(--env-file "$env_file")
  if [[ -n "$web_port" ]]; then
    args+=(--publish "127.0.0.1:${web_port}:${WEB_CONTAINER_PORT:-3080}")
  fi
  args+=("$image")
  run_engine "${args[@]}"
}

# eng_create_ephemeral NAME IMAGE ENV_FILE AGENT COMMAND
#
# One-shot containers get no volume and no host directory: their working
# directory is /home/agent inside the image. Nothing they write is meant to
# outlive them, which is why there is no home volume to mount.
eng_create_ephemeral() {
  local name="$1" image="$2" env_file="$3" agent="$4" command="$5"
  local -a args=(run --rm --name "$name" --hostname "$name")
  if [[ -t 0 ]] && [[ -t 1 ]]; then
    args+=(--interactive --tty)
  fi
  args+=(--label "${LABEL_KEY}=${LABEL_VALUE}")
  args+=(--label "${LABEL_NS}.agent=${agent}")
  args+=(--label "${LABEL_NS}.mode=ephemeral")
  args+=(--workdir "/home/${AGENT_USER}")
  args+=(--env "AGENT_WORKSPACE_AGENT=${agent}")
  [[ -f "$env_file" ]] && args+=(--env-file "$env_file")
  args+=("$image" "$command")
  run_engine "${args[@]}"
}
