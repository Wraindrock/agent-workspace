#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Container management commands.
#
# A container created here is a complete Linux system running in podman or
# docker. The installer keeps enough state next to it to make it
# snapshottable, rollback-able, recoverable and forkable:
#
#   snapshot  commit the container filesystem + archive the home volume
#   rollback  recreate the container from a snapshot
#   recover   bring a lost or stopped container back
#   fork      branch a new container off an existing one
#   upgrade   move to a newer image, snapshotting first
# ---------------------------------------------------------------------------

# --- small helpers ---------------------------------------------------------

require_container() {
  state_exists "${1}" || die_k err_no_such_container "${1}"
}

container_agent()      { state_get "${1}" AGENT; }
container_mode()       { state_get "${1}" MODE; }
container_workspace()  { state_get "${1}" WORKSPACE; }
container_run_image()  { local ref; ref="$(state_get "${1}" RUN_IMAGE)"; printf '%s' "${ref:-$(state_get "${1}" IMAGE)}"; }

container_home_volume() {
  local vol
  vol="$(state_get "${1}" VOLUME)"
  printf '%s' "${vol:-$(volume_name "${1}")}"
}

state_engine() {
  local engine
  engine="$(state_get "${1}" ENGINE)"
  use_engine "${engine:-$ENGINE}"
}

state_engine_soft() {
  local engine
  engine="$(state_get "${1}" ENGINE)"
  [[ -n "$engine" ]] || engine="$ENGINE"
  if command -v "$engine" >/dev/null 2>&1; then
    ENGINE="$engine"
    ENGINE_BIN="$engine"
  fi
}

# ensure_image REF: make REF ready to create from, refreshing a tag that moved.
#
# "The image is here" is not "the image is current". A digest cannot change, so a
# local copy of one is already the right answer. A tag can: `latest` is whatever
# the registry serves *now*, and a local copy of it can be days old. Treating
# presence as freshness is how a user ends up running code from before the fix
# they are waiting for - one host ran a three-day-old image whose dangling /home
# symlink made the engine die with `crun: creating '/home/agent': openat2 'home':
# No such file or directory`, an error that reads like an engine bug and was not
# one. So refresh tags, and keep --no-pull as the explicit "use whatever is here"
# escape for a machine with no network.
ensure_image() {
  local ref="${1}"
  # A locally built image (snapshots, dev builds) has no registry to ask, and a
  # digest cannot have moved: for both of them presence is the whole test.
  if [[ "$ref" == *"@sha256:"* ]] || [[ "$ref" == localhost/* ]]; then
    eng_image_exists "$ref" && return 0
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
      run_engine pull "$ref"
      return 0
    fi
    [[ "${NO_PULL:-0}" -eq 1 ]] && die_k err_image_missing "${ref}"
    pull_or_die "$ref"
    return 0
  fi
  if [[ "${NO_PULL:-0}" -eq 1 ]]; then
    eng_image_exists "$ref" || die_k err_image_missing "${ref}"
    return 0
  fi
  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    # A dry run does not touch the registry, but it does say what a real run does.
    run_engine pull "$ref"
    return 0
  fi
  refresh_image "$ref"
}

pull_image() {
  if [[ -n "${GUM_BIN:-}" ]]; then
    ui_spin "$(tf pulling "${1}")" "$ENGINE_BIN" pull "$1"
  else
    "$ENGINE_BIN" pull "$1"
  fi
}

# pull_or_die REF: pull, with nothing to fall back on.
pull_or_die() {
  local ref="${1}"
  msg_k pulling "${ref}"
  pull_image "$ref" || die_k err_pull_failed "${ref}"
}

# refresh_image REF: pull REF, but never lose a usable local copy to a registry
# that is merely unreachable. Either way it names the copy about to be used, with
# its id - and its build time when falling back - because silently running a stale
# image is the bug this exists to prevent.
refresh_image() {
  local ref="${1}" existed=0
  eng_image_exists "$ref" && existed=1
  msg_k pulling "${ref}"
  if pull_image "$ref"; then
    ok_k image_refreshed "${ref}" "$(eng_image_id "$ref")"
    return 0
  fi
  if [[ "$existed" -eq 1 ]]; then
    warn_k warn_pull_failed "${ref}" "$(eng_image_id "$ref")" "$(eng_image_created "$ref")"
    return 0
  fi
  die_k err_pull_failed "${ref}"
}

confirm() {
  [[ "${ASSUME_YES:-0}" -eq 1 ]] && return 0
  # A prompt nobody can answer is not a "no". With no terminal the answer would be
  # an EOF read, and a destructive command that aborts on EOF and exits 0 is
  # indistinguishable from one that succeeded -- the caller's `remove box && ...`
  # would run its success branch over a container that is still there. Refuse
  # explicitly instead, and make the scripted caller say --yes.
  if ! ui_enabled; then
    die_k err_refuse_no_confirm
  fi
  ui_confirm "${1}"
}

# --- create ----------------------------------------------------------------

# create_container_from NAME AGENT MODE WORKSPACE IMAGE_REF [DECLARED_IMAGE]
create_container_from() {
  local name="${1}" agent="${2}" mode="${3}" workspace="${4}" image_ref="${5}" declared="${6:-${5}}"
  local env_file volume web web_port
  env_file="$(env_file_for "$name")"
  volume="$(volume_name "$name")"

  # The agent web UI is published on the host loopback only. The port is stored in
  # the container state so rollback, recover and upgrade republish the same port;
  # a fork has a new name and therefore gets a fresh port.
  web="${WEB_ENABLED:-1}"
  web_port=""
  if state_exists "$name"; then
    web="$(state_get "$name" WEB)"
    [[ -n "$web" ]] || web="${WEB_ENABLED:-1}"
    web_port="$(state_get "$name" WEB_HOST_PORT)"
  fi
  if [[ -n "${WEB_HOST_PORT_REQUEST:-}" ]]; then
    web=1
    web_port="${WEB_HOST_PORT_REQUEST}"
  elif [[ "$web" == "1" && -z "$web_port" ]]; then
    web_port="$(free_web_port "${WEB_PORT_BASE:-3080}")"
  fi
  if [[ "$mode" != "persistent" ]]; then
    # an ephemeral container exits with its command, so a web UI would die with it
    web=0
    web_port=""
  fi
  if [[ "$web" == "1" ]] && ! agent_web_command "$agent" >/dev/null 2>&1; then
    # Nothing can serve this port, so publishing it would only hand out a URL that
    # resets the connection. Say so when a port was asked for explicitly.
    if [[ -n "${WEB_HOST_PORT_REQUEST:-}" ]]; then
      warn_k warn_no_web_ui "${agent}" "${name}"
    fi
    web=0
    web_port=""
  fi

  case "$mode" in
    persistent)
      eng_volume_exists "$volume" || run_engine volume create "$volume" >/dev/null
      local -a args=(run --name "$name" --hostname "$name")
      local flag
      while IFS= read -r flag; do args+=("$flag"); done < <(engine_run_flags)
      args+=(--label "${LABEL_KEY}=${LABEL_VALUE}")
      args+=(--label "${LABEL_NS}.agent=$agent")
      args+=(--label "${LABEL_NS}.mode=$mode")
      args+=(--volume "${volume}:/home/${AGENT_USER}")
      args+=(--volume "${workspace}:/workspace$(engine_mount_suffix)")
      args+=(--workdir /workspace)
      args+=(--env "AGENT_WORKSPACE_AGENT=$agent")
      [[ -f "$env_file" ]] && args+=(--env-file "$env_file")
      if [[ "$web" == "1" && -n "$web_port" ]]; then
        args+=(--publish "127.0.0.1:${web_port}:${WEB_CONTAINER_PORT:-3080}")
      fi
      args+=("$image_ref")
      run_engine "${args[@]}"
      if [[ "${DRY_RUN:-0}" -eq 0 ]]; then
        # Wait for the container to reach "running" instead of trusting that it
        # did: a container that exits on start (a dangling /home, an image whose
        # command is not systemd) used to be reported as created. The wait is a
        # liveness probe, not a fixed sleep, and it is bounded.
        local waited=0 timeout="${CONTAINER_READY_TIMEOUT:-30}"
        until eng_container_running "$name"; do
          if [[ "${waited}" -ge "${timeout}" ]]; then
            warn_k err_did_not_stay_up "${name}"
            "$ENGINE_BIN" logs --tail 20 "$name" 2>/dev/null || true
            die_k err_not_running "${name}"
          fi
          sleep 1
          waited=$((waited + 1))
        done
      fi
      ;;
    ephemeral)
      if [[ -n "${WEB_HOST_PORT_REQUEST:-}" ]]; then
        warn_k warn_web_port_ephemeral
      fi
      local -a eargs=(run --rm --name "$name" --hostname "$name")
      if [[ -t 0 ]] && [[ -t 1 ]]; then
        eargs+=(--interactive --tty)
      fi
      eargs+=(--label "${LABEL_KEY}=${LABEL_VALUE}")
      eargs+=(--label "${LABEL_NS}.agent=$agent")
      eargs+=(--label "${LABEL_NS}.mode=$mode")
      eargs+=(--volume "${workspace}:/workspace$(engine_mount_suffix)")
      eargs+=(--workdir /workspace)
      eargs+=(--env "AGENT_WORKSPACE_AGENT=$agent")
      [[ -f "$env_file" ]] && eargs+=(--env-file "$env_file")
      eargs+=("$image_ref" "$(agent_launch_command "$agent")")
      run_engine "${eargs[@]}"
      ;;
    *)
      die_k err_unknown_mode "${mode}"
      ;;
  esac

  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    return 0
  fi
  state_set "$name" ENGINE "$ENGINE"
  state_set "$name" AGENT "$agent"
  state_set "$name" MODE "$mode"
  state_set "$name" WORKSPACE "$workspace"
  state_set "$name" VOLUME "$volume"
  state_set "$name" IMAGE "$declared"
  state_set "$name" RUN_IMAGE "$image_ref"
  state_set "$name" WEB "$web"
  if [[ "$mode" == "persistent" && -n "$web_port" ]]; then
    state_set "$name" WEB_HOST_PORT "$web_port"
  fi
  state_set "$name" CREATED "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  state_record_event "$name" "created from ${image_ref}"
}

# --- queries ---------------------------------------------------------------

cmd_list() {
  local names name agent mode engine status snapshots web
  names="$(state_list)"
  if [[ -z "$names" ]]; then
    msg_k no_containers_yet "install.sh create"
    return 0
  fi
  printf '%-18s %-10s %-11s %-8s %-9s %-6s %s\n' "$(t col_name)" "$(t col_agent)" "$(t col_mode)" "$(t col_engine)" "$(t col_state)" "$(t col_web)" "$(t col_snapshots)"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    state_engine_soft "$name"
    agent="$(container_agent "$name")"
    mode="$(container_mode "$name")"
    engine="$(state_get "$name" ENGINE)"
    if eng_container_exists "$name"; then
      if eng_container_running "$name"; then status="running"; else status="stopped"; fi
    else
      status="missing"
    fi
    snapshots="$(snapshot_list "$name" | grep -c . || true)"
    web="$(state_get "$name" WEB)"
    if [[ "$web" == "1" ]]; then
      web="$(state_get "$name" WEB_HOST_PORT)"
      [[ -n "$web" ]] || web="-"
    else
      web="-"
    fi
    printf '%-18s %-10s %-11s %-8s %-9s %-6s %s\n' "$name" "$agent" "$mode" "$engine" "$status" "$web" "$snapshots"
  done <<<"$names"
}

cmd_snapshots() {
  local name="${1}" ids id created label size
  require_container "$name"
  ids="$(snapshot_list "$name")"
  if [[ -z "$ids" ]]; then
    msg_k no_snapshots "${name}"
    return 0
  fi
  printf '%-22s %-21s %-12s %s\n' "$(t col_id)" "$(t col_created)" "$(t col_label)" "$(t col_size)"
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    created="$(snapshot_get "$name" "$id" CREATED)"
    label="$(snapshot_get "$name" "$id" LABEL)"
    if [[ -f "$(snapshot_path "$name" "$id")/home.tar.gz" ]]; then
      size="$(du -h "$(snapshot_path "$name" "$id")/home.tar.gz" | cut -f1)"
    else
      size="-"
    fi
    printf '%-22s %-21s %-12s %s\n' "$id" "${created:-$(t unknown_value)}" "${label:--}" "$size"
  done <<<"$ids"
}

# --- lifecycle -------------------------------------------------------------

cmd_start() {
  local name="${1}"
  require_container "$name"
  state_engine "$name"
  if eng_container_running "$name"; then
    ok_k already_running "${name}"
  else
    eng_start "$name" >/dev/null
    ok_k started "${name}"
  fi
  # The web UI is a process inside the container, so stopping the container kills
  # it: whichever command brings the container up brings its published UI up too,
  # instead of leaving the port to reset the connection.
  web_ui_bring_up "$name" || true
}

cmd_stop() {
  local name="${1}"
  require_container "$name"
  state_engine "$name"
  eng_stop "$name"
  ok_k stopped_name "${name}"
}

cmd_restart() {
  local name="${1}"
  require_container "$name"
  state_engine "$name"
  eng_stop "$name"
  eng_start "$name" >/dev/null
  ok_k restarted "${name}"
  web_ui_bring_up "$name" || true
}

cmd_logs() {
  local name="${1}"
  require_container "$name"
  state_engine "$name"
  if [[ "${LOGS_FOLLOW:-0}" -eq 1 ]]; then
    run_engine logs --tail "${LOGS_TAIL:-50}" --follow "$name"
  else
    run_engine logs --tail "${LOGS_TAIL:-50}" "$name"
  fi
}

cmd_enter() {
  local name="${1}"
  shift
  require_container "$name"
  state_engine "$name"
  if [[ "$(container_mode "$name")" == "ephemeral" ]]; then
    die_k err_ephemeral_enter "${name}"
  fi
  if ! eng_container_running "$name"; then
    msg_k starting_name "${name}"
    eng_start "$name" >/dev/null
    sleep 2
  fi
  if ! eng_container_running "$name"; then
    die_k err_not_running_try "${name}" "install.sh logs ${name}"
  fi
  if [[ "${#}" -gt 0 ]]; then
    eng_exec "$name" "$@"
  else
    eng_exec "$name" "$(agent_launch_command "$(container_agent "$name")")"
  fi
}

# --- agent web UI ----------------------------------------------------------

# agent_web_command AGENT prints the in-container command that starts the agent's
# web UI, or fails when this installer does not know how to open one.
agent_web_command() {
  case "${1:-}" in
    dsh) printf 'dsh web --patch /usr/share/agent-workspace/dsh-web.yml --no-open' ;;
    *) return 1 ;;
  esac
}

# container_web_up NAME PORT succeeds when the port inside the container accepts
# a connection. Bash's /dev/tcp keeps this independent of curl or nc, neither of
# which is guaranteed to be in the image.
container_web_up() {
  local name="${1}" port="${2}"
  "$ENGINE_BIN" exec "$name" /bin/bash -c "exec 3<>/dev/tcp/127.0.0.1/${port}" >/dev/null 2>&1
}

# web_ui_start NAME starts the agent's web UI inside a running container, waits
# for the launch token and prints the one-time sign-in URL on the host loopback.
# Shared by `install.sh web` and by every command that leaves a container running,
# so a published port never answers with a connection reset. Fails when this
# installer has no web UI to open for the agent, or the container publishes none.
web_ui_start() {
  local name="${1}" agent webcmd port log_dir log_file token running=0 i
  agent="$(container_agent "$name")"
  webcmd="$(agent_web_command "$agent")" || return 1

  port="$(state_get "$name" WEB_HOST_PORT)"
  if [[ -z "$port" ]]; then
    port="$(eng_host_port "$name" "${WEB_CONTAINER_PORT:-3080}")"
    port="${port##*:}"
  fi
  [[ -n "$port" ]] || return 1

  log_dir="/home/${AGENT_USER}/.cache/agent-workspace"
  log_file="${log_dir}/${agent}-web.log"

  if container_web_up "$name" "${WEB_CONTAINER_PORT:-3080}"; then
    running=1
    msg_k web_already_running "${name}"
  fi

  if [[ "$running" -eq 0 ]]; then
    run_engine exec --detach --user "$AGENT_USER" --env "HOME=/home/${AGENT_USER}" "$name" \
      /bin/bash -c "install -d -m 0700 ${log_dir} && : >${log_file} && exec ${webcmd} >>${log_file} 2>&1"
  fi

  token=""
  for ((i = 0; i < 20; i++)); do
    token="$("$ENGINE_BIN" exec "$name" /bin/bash -c "grep -o 'token=[A-Za-z0-9_-]*' ${log_file} 2>/dev/null | tail -n 1 | cut -d= -f2" 2>/dev/null || true)"
    [[ -n "$token" ]] && break
    sleep 1
  done

  ok_k web_published "${agent}" "${port}" "${WEB_CONTAINER_PORT:-3080}"
  if [[ -n "$token" ]]; then
    msg_k web_open_url "${port}" "${token}"
    msg_k web_first_visit "${port}"
  else
    warn_k web_no_token "${log_file}"
  fi
  return 0
}

# wait_agent_ready NAME [TIMEOUT] succeeds once the container's first boot has
# finished provisioning, which is when the agent user exists. `dsh web` runs as
# that user, so starting it earlier fails with "unable to find user agent"; the
# marker file is the readiness probe (a bounded wait, never a fixed sleep), and
# the wait gives up as soon as the container stops.
wait_agent_ready() {
  local name="${1}" timeout="${2:-${CONTAINER_FIRSTBOOT_TIMEOUT:-180}}" waited=0
  while [[ "$waited" -lt "$timeout" ]]; do
    if "$ENGINE_BIN" exec "$name" /bin/bash -c 'test -f /var/lib/agent-workspace/.provisioned' >/dev/null 2>&1; then
      return 0
    fi
    eng_container_running "$name" || return 1
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

# web_ui_bring_up NAME brings a container's web UI up, or says why it did not.
# Returns 1 when the container publishes no web UI, when this installer has none
# to open for the agent, or when the first boot is still running -- the last two
# with a warning, because the caller promised a UI on a published port. Callers
# that must not fail (the lifecycle commands) simply ignore the status.
web_ui_bring_up() {
  local name="${1}" agent
  state_engine "$name"
  [[ "$(state_get "$name" WEB)" == "1" ]] || return 1
  agent="$(container_agent "$name")"
  agent_web_command "$agent" >/dev/null 2>&1 || return 1
  if ! wait_agent_ready "$name"; then
    warn_k warn_firstboot_pending "${name}" "${CONTAINER_FIRSTBOOT_TIMEOUT:-180}"
    return 1
  fi
  msg_k web_starting "${name}"
  web_ui_start "$name"
}

# cmd_web NAME starts the agent's web UI inside the container, waits for the
# launch token and prints a one-time sign-in URL on the host loopback.
cmd_web() {
  local name="${1}" port agent
  require_container "$name"
  state_engine "$name"
  agent="$(container_agent "$name")"

  if [[ "$(container_mode "$name")" != "persistent" ]]; then
    die_k err_web_ephemeral "${name}"
  fi
  agent_web_command "$agent" >/dev/null || die_k err_no_web_ui "${agent}"
  if [[ "$(state_get "$name" WEB)" == "0" ]]; then
    die_k err_web_no_web "${name}"
  fi

  port="$(state_get "$name" WEB_HOST_PORT)"
  if [[ -z "$port" ]]; then
    port="$(eng_host_port "$name" "${WEB_CONTAINER_PORT:-3080}")"
    port="${port##*:}"
  fi
  [[ -n "$port" ]] || die_k err_web_no_port "${name}" "${name}"

  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    printf 'dry-run: %s exec --detach --user %s --env HOME=/home/%s %s /bin/bash -c %q\n' \
      "$ENGINE_BIN" "$AGENT_USER" "$AGENT_USER" "$name" "$(agent_web_command "$agent")"
    printf '%s\n' "$(tf dry_url "$port")"
    return 0
  fi

  if ! eng_container_running "$name"; then
    eng_start "$name" >/dev/null 2>&1 || true
    sleep 2
  fi
  eng_container_running "$name" || die_k err_start_it "${name}"

  # The UI runs as the agent user, which the first boot creates. An explicit
  # `install.sh web` waits for that instead of reporting a token it cannot read.
  if ! wait_agent_ready "$name"; then
    die_k err_firstboot_pending "${name}" "${CONTAINER_FIRSTBOOT_TIMEOUT:-180}"
  fi

  web_ui_start "$name" || die_k err_no_web_ui "${agent}"
}

# --- snapshots -------------------------------------------------------------

# home_archive_ok ARCHIVE succeeds when a home archive exists and can be listed
# back. A snapshot that cannot restore the home is worse than no snapshot, so
# anything that fails here is never kept.
home_archive_ok() {
  local archive="${1}"
  [[ -s "$archive" ]] || return 1
  tar -tzf "$archive" >/dev/null 2>&1
}

archive_home_volume() {
  local name="${1}" id="${2}" volume="" dir="" image=""
  volume="$(container_home_volume "$name")"
  dir="$(snapshot_path "$name" "$id")"
  image="$(snapshot_image "$name" "$id")"
  if ! eng_volume_exists "$volume"; then
    warn_k snap_no_volume "${volume}"
    return 0
  fi
  if run_engine run --rm --entrypoint /usr/bin/tar --volume "${volume}:/data:ro" \
      --volume "${dir}:/backup$(engine_mount_suffix)" "$image" czf /backup/home.tar.gz -C /data .; then
    if home_archive_ok "${dir}/home.tar.gz"; then
      ok_k snap_archived "${dir}"
    else
      rm -f "${dir}/home.tar.gz"
      warn_k snap_archive_unreadable "${id}"
    fi
  else
    warn_k snap_no_tar "${volume}"
  fi
}

restore_home_volume() {
  local name="${1}" id="${2}" volume="" dir="" image="" entries=""
  volume="$(container_home_volume "$name")"
  dir="$(snapshot_path "$name" "$id")"
  image="$(snapshot_image "$name" "$id")"
  if [[ ! -s "${dir}/home.tar.gz" ]]; then
    warn_k snap_no_archive "${id}"
    return 0
  fi
  if ! home_archive_ok "${dir}/home.tar.gz"; then
    die_k snap_archive_bad "${id}" "${dir}"
  fi
  entries="$(tar -tzf "${dir}/home.tar.gz" 2>/dev/null | grep -c . || true)"
  if ! eng_volume_exists "$volume"; then
    run_engine volume create "$volume" >/dev/null
  fi
  run_engine run --rm --entrypoint /usr/bin/tar --volume "${volume}:/data" \
    --volume "${dir}:/backup$(engine_mount_suffix)" "$image" xzf /backup/home.tar.gz -C /data
  ok_k home_restored "${id}" "${entries:-0}"
}

# cmd_snapshot NAME [LABEL] [SOFT] commits the filesystem and archives the home
# volume. SOFT=1 turns a failure into a warning and a non-zero return, which is
# what the safety snapshot in a rollback needs: a broken container must not stop
# the repair the user asked for.
cmd_snapshot() {
  local name="${1}" label="${2:-manual}" soft="${3:-0}" id="" ref="" dir=""
  require_container "$name"
  state_engine "$name"
  id="$(snapshot_next_id "$name")"
  ref="$(snapshot_image "$name" "$id")"
  dir="$(snapshot_path "$name" "$id")"
  install -d -m 0700 "$dir"
  if ! eng_commit "$name" "$ref"; then
    rm -rf "$dir"
    if [[ "$soft" -eq 1 ]]; then
      warn_k warn_no_safety_snap "${name}"
      return 1
    fi
    die_k err_could_not_snapshot "${name}" "${name}"
  fi
  create_snapshot_meta "$name" "$id" "$label" "$ref"
  archive_home_volume "$name" "$id"
  state_set "$name" SNAPSHOT_LAST "$id"
  state_record_event "$name" "snapshot ${id} (${label})"
  snapshot_prune "$name" "${SNAPSHOT_KEEP:-5}"
  ok_k snapshot_created "${id}" "${name}" "${label}"
}

create_snapshot_meta() {
  local name="${1}" id="${2}" label="${3}" ref="${4}" dir=""
  dir="$(snapshot_path "$name" "$id")"
  install -d -m 0700 "$dir"
  {
    printf 'ID=%s\n' "$id"
    printf 'CONTAINER=%s\n' "$name"
    printf 'CREATED=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'LABEL=%s\n' "$label"
    printf 'ENGINE=%s\n' "$ENGINE"
    printf 'IMAGE=%s\n' "$(state_get "$name" IMAGE)"
    printf 'RUN_IMAGE=%s\n' "$(state_get "$name" RUN_IMAGE)"
    printf 'SNAPSHOT_IMAGE=%s\n' "$ref"
    printf 'AGENT=%s\n' "$(container_agent "$name")"
    printf 'MODE=%s\n' "$(container_mode "$name")"
    printf 'WORKSPACE=%s\n' "$(container_workspace "$name")"
  } >"${dir}/meta"
  chmod 0600 "${dir}/meta"
}

snapshot_ref() {
  local name="${1}" id="${2}" ref=""
  ref="$(snapshot_get "$name" "$id" SNAPSHOT_IMAGE)"
  printf '%s' "${ref:-$(snapshot_image "$name" "$id")}"
}

resolve_snapshot() {
  local name="${1}" wanted="${2}" id=""
  if [[ -n "$wanted" ]]; then
    id="$wanted"
  else
    id="$(state_get "$name" SNAPSHOT_LAST)"
    [[ -n "$id" ]] || id="$(snapshot_latest "$name")"
  fi
  [[ -n "$id" ]] || die_k err_no_snapshot "${name}"
  [[ -f "$(snapshot_meta "$name" "$id")" ]] || die_k err_snapshot_not_found "${id}" "${name}"
  printf '%s' "$id"
}

cmd_rollback() {
  local name="${1}" target="${2:-}" id="" ref="" agent="" mode="" workspace="" declared="" archive=""
  require_container "$name"
  state_engine "$name"
  id="$(resolve_snapshot "$name" "$target")"
  ref="$(snapshot_ref "$name" "$id")"
  if [[ "${DRY_RUN:-0}" -eq 0 ]] && ! eng_image_exists "$ref"; then
    die_k snap_image_gone "${ref}" "${id}"
  fi
  # refuse before anything is destroyed: a container that has already been
  # removed cannot be brought back if the archive turns out to be unreadable
  archive="$(snapshot_path "$name" "$id")/home.tar.gz"
  if [[ -e "$archive" ]] && ! home_archive_ok "$archive"; then
    die_k snap_archive_bad2 "${id}" "${archive}"
  fi
  confirm "$(tf confirm_rollback "${name}" "${id}")" || { warn_k aborted; return 1; }
  agent="$(container_agent "$name")"
  mode="$(container_mode "$name")"
  workspace="$(container_workspace "$name")"
  declared="$(snapshot_get "$name" "$id" IMAGE)"
  [[ -n "$declared" ]] || declared="$(state_get "$name" IMAGE)"
  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    printf '%s\n' "$(tf dry_snapshot_rollback "$name")"
  elif [[ "${SKIP_SAFETY:-0}" -eq 1 ]]; then
    msg_k skip_safety
  elif eng_container_exists "$name"; then
    # the container is replaced below; keep what it looks like now, so a
    # rollback that turns out to be a mistake is itself reversible
    msg_k snapshotting_before_rollback "${name}"
    cmd_snapshot "$name" "pre-rollback" 1 || true
  fi
  eng_stop "$name"
  eng_remove "$name"
  restore_home_volume "$name" "$id"
  create_container_from "$name" "$agent" "$mode" "$workspace" "$ref" "$declared"
  state_set "$name" SNAPSHOT_LAST "$id"
  state_record_event "$name" "rolled back to ${id}"
  ok_k rolled_back_to "${name}" "${id}"
  # the container was replaced, so its web UI has to come back with it
  web_ui_bring_up "$name" || true
}

cmd_recover() {
  local name="${1}" id="" ref="" agent="" mode="" workspace="" declared="" image=""
  require_container "$name"
  state_engine "$name"

  if eng_container_exists "$name"; then
    if eng_container_running "$name"; then
      ok_k recover_running "${name}"
      web_ui_bring_up "$name" || true
      return 0
    fi
    eng_start "$name" >/dev/null
    sleep 2
    if eng_container_running "$name"; then
      ok_k recovered_restart "${name}"
      web_ui_bring_up "$name" || true
    else
      warn_k recover_not_staying_up "${name}" "${name}"
    fi
    return 0
  fi

  agent="$(container_agent "$name")"
  mode="$(container_mode "$name")"
  workspace="$(container_workspace "$name")"
  id="$(state_get "$name" SNAPSHOT_LAST)"
  [[ -n "$id" ]] || id="$(snapshot_latest "$name")"

  if [[ -n "$id" ]] && [[ -f "$(snapshot_meta "$name" "$id")" ]]; then
    ref="$(snapshot_ref "$name" "$id")"
    declared="$(snapshot_get "$name" "$id" IMAGE)"
    [[ -n "$declared" ]] || declared="$(state_get "$name" IMAGE)"
    restore_home_volume "$name" "$id"
    create_container_from "$name" "$agent" "$mode" "$workspace" "$ref" "$declared"
    state_set "$name" SNAPSHOT_LAST "$id"
    state_record_event "$name" "recovered from ${id}"
    ok_k recovered_from_snap "${name}" "${id}"
    web_ui_bring_up "$name" || true
  else
    image="$(container_run_image "$name")"
    [[ -n "$image" ]] || image="$IMAGE"
    ensure_image "$image"
    create_container_from "$name" "$agent" "$mode" "$workspace" "$image" "$(state_get "$name" IMAGE)"
    state_record_event "$name" "recovered from image ${image}"
    warn_k warn_rebuilt "${name}" "${image}"
    web_ui_bring_up "$name" || true
  fi
}

cmd_fork() {
  local src="${1}" new="${2}" agent="${3:-}" mode="${4:-}" workspace="${5:-}" snap="${6:-}"
  local image="" src_volume="" new_volume="" engine=""
  require_container "$src"
  validate_name "$new" || die_k err_invalid_name "${new}"
  state_exists "$new" && die_k err_name_exists "${new}"
  engine="$(state_get "$src" ENGINE)"
  use_engine "${engine:-$ENGINE}"
  agent="${agent:-$(container_agent "$src")}"
  agent_known "$agent" || die_k err_unknown_agent "${agent}"
  mode="${mode:-$(container_mode "$src")}"
  workspace="${workspace:-$(default_workspace "$new")}"

  if [[ -n "$snap" ]]; then
    snap="$(resolve_snapshot "$src" "$snap")"
    image="$(snapshot_ref "$src" "$snap")"
  elif [[ "${FORK_LIVE:-0}" -eq 1 ]]; then
    image="$(container_run_image "$src")"
  else
    msg_k snapshotting_before_fork "${src}"
    cmd_snapshot "$src" "fork-source" >/dev/null
    snap="$(state_get "$src" SNAPSHOT_LAST)"
    image="$(snapshot_ref "$src" "$snap")"
  fi

  new_volume="$(volume_name "$new")"
  eng_volume_exists "$new_volume" && die_k err_volume_exists "${new_volume}"
  run_engine volume create "$new_volume" >/dev/null

  if [[ -n "$snap" ]] && [[ -s "$(snapshot_path "$src" "$snap")/home.tar.gz" ]]; then
    msg_k forking_copy_snap "${snap}"
    run_engine run --rm --entrypoint /usr/bin/tar --volume "${new_volume}:/data" \
      --volume "$(snapshot_path "$src" "$snap"):/backup$(engine_mount_suffix)" "$image" \
      xzf /backup/home.tar.gz -C /data
  else
    src_volume="$(container_home_volume "$src")"
    if eng_volume_exists "$src_volume"; then
      msg_k forking_copy_live "${src_volume}"
      run_engine run --rm --entrypoint /bin/bash --volume "${src_volume}:/from:ro" --volume "${new_volume}:/to" \
        "$image" -c 'cd /from && tar cf - . | tar xf - -C /to'
    fi
  fi

  local src_env="" new_env=""
  src_env="$(env_file_for "$src")"
  new_env="$(env_file_for "$new")"
  if [[ -f "$src_env" ]]; then
    install -d -m 0700 "$CONF_HOME/containers"
    umask 077
    cp "$src_env" "$new_env"
    chmod 0600 "$new_env"
    warn_k fork_copied_creds "${src}" "${new_env}"
  fi

  create_container_from "$new" "$agent" "$mode" "$workspace" "$image" "$(state_get "$src" IMAGE)"
  state_set "$new" FORKED_FROM "$src"
  [[ -n "$snap" ]] && state_set "$new" FORKED_AT "$snap"
  ok_k forked_into "${src}" "${new}" "${agent}" "${mode}"
  # a fork is a new container with its own fresh port: bring that UI up as well
  web_ui_bring_up "$new" || true
}

cmd_upgrade() {
  local name="${1}" target="${2:-}" agent="" mode="" workspace=""
  require_container "$name"
  state_engine "$name"
  [[ -n "$target" ]] || target="$(state_get "$name" IMAGE)"
  [[ -n "$target" ]] || target="$IMAGE"
  ensure_image "$target"
  confirm "$(tf confirm_upgrade "${name}" "${target}")" || { warn_k aborted; return 1; }
  cmd_snapshot "$name" "pre-upgrade" >/dev/null
  agent="$(container_agent "$name")"
  mode="$(container_mode "$name")"
  workspace="$(container_workspace "$name")"
  eng_stop "$name"
  eng_remove "$name"
  create_container_from "$name" "$agent" "$mode" "$workspace" "$target" "$target"
  state_record_event "$name" "upgraded to ${target}"
  ok_k upgraded_named "${name}" "${target}"
  web_ui_bring_up "$name" || true
}

cmd_remove() {
  local name="${1}" id=""
  require_container "$name"
  state_engine "$name"
  confirm "$(tf confirm_remove "${name}")" || { warn_k aborted; return 1; }
  if eng_container_exists "$name"; then
    eng_stop "$name"
    eng_remove "$name"
  fi
  if [[ "${KEEP_VOLUME:-0}" -eq 1 ]]; then
    msg_k kept_volume "$(container_home_volume "$name")"
  else
    eng_volume_remove "$(container_home_volume "$name")"
  fi
  rm -f "$(env_file_for "$name")"
  if [[ "${PURGE_SNAPSHOTS:-0}" -eq 1 ]]; then
    local kept=0
    while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      # force=1 drops the records the user asked to drop, but never the image a
      # container still runs from (image_in_use in installer/lib/state.sh)
      snapshot_delete "$name" "$id" 1 || kept=$((kept + 1))
    done < <(snapshot_list "$name")
    if [[ "$kept" -eq 0 ]]; then
      rm -rf "$(snapshot_root "$name")"
    else
      msg_k kept_snapshots_in_use "${kept}" "$(snapshot_root "$name")"
    fi
  else
    msg_k kept_snapshots "${name}" "$(snapshot_root "$name")"
  fi
  rm -rf "$(state_dir "$name")"
  ok_k removed_named "${name}"
}

# --- host doctor -----------------------------------------------------------

cmd_doctor() {
  local problems=0 names name engine status image volume env_file id archive web mapped
  heading_k head_environment
  local available
  available="$(detect_engines)"
  if [[ -z "$available" ]]; then
    report_bad_k doc_no_engine
    problems=$((problems + 1))
  else
    while IFS= read -r engine; do
      [[ -n "$engine" ]] || continue
      report_ok_k doc_engine "${engine}" "$("$engine" --version 2>/dev/null | head -n 1)"
    done <<<"$available"
  fi
  report_ok_k doc_state_dir "${DATA_HOME}"
  report_ok_k doc_conf_dir "${CONF_HOME}/containers"

  names="$(state_list)"
  if [[ -z "$names" ]]; then
    report_ok_k doc_no_containers
  fi
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    heading_k head_container "${name}"
    state_engine_soft "$name"
    engine="$(state_get "$name" ENGINE)"
    if ! command -v "$engine" >/dev/null 2>&1; then
      report_bad_k doc_engine_missing "${engine}"
      problems=$((problems + 1))
    elif eng_container_exists "$name"; then
      status="$(eng_container_status "$name")"
      report_ok_k doc_container_exists "${status}"
    else
      report_bad_k doc_container_missing "${name}"
      problems=$((problems + 1))
    fi

    image="$(container_run_image "$name")"
    if command -v "$engine" >/dev/null 2>&1; then
      if eng_image_exists "$image"; then
        report_ok_k doc_image_present "${image}"
      else
        report_bad_k doc_image_missing "${image}" "${name}"
        problems=$((problems + 1))
      fi
    fi

    volume="$(container_home_volume "$name")"
    if [[ "$(container_mode "$name")" == "persistent" ]]; then
      if command -v "$engine" >/dev/null 2>&1 && eng_volume_exists "$volume"; then
        report_ok_k doc_volume_present "${volume}"
      else
        report_bad_k doc_volume_missing "${volume}"
        problems=$((problems + 1))
      fi
    fi

    env_file="$(env_file_for "$name")"
    if [[ -f "$env_file" ]]; then
      local mode_bits
      mode_bits="$(stat -c '%a' "$env_file" 2>/dev/null || printf 'unknown')"
      if [[ "$mode_bits" == "600" ]]; then
        report_ok_k doc_creds_ok "${env_file}"
      else
        report_bad_k doc_creds_mode "${env_file}" "${mode_bits}"
        problems=$((problems + 1))
      fi
    fi

    web="$(state_get "$name" WEB)"
    if [[ "$web" == "1" ]] && command -v "$engine" >/dev/null 2>&1 && eng_container_exists "$name"; then
      local mapped
      mapped="$(eng_host_port "$name" "${WEB_CONTAINER_PORT:-3080}")"
      if [[ -n "$mapped" ]]; then
        report_ok_k doc_web_ok "${mapped}"
      else
        report_bad_k doc_web_missing "${name}"
        problems=$((problems + 1))
      fi
    fi

    while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      archive="$(snapshot_path "$name" "$id")/home.tar.gz"
      if [[ -f "$archive" ]]; then
        if tar -tzf "$archive" >/dev/null 2>&1; then
          report_ok_k doc_snap_ok "${id}"
        else
          report_bad_k doc_snap_bad "${id}" "${archive}"
          problems=$((problems + 1))
        fi
      fi
    done < <(snapshot_list "$name")
  done <<<"$names"

  heading_k head_result
  if [[ "$problems" -eq 0 ]]; then
    ok_k doctor_clean
    return 0
  fi
  warn_k doctor_problems "${problems}"
  if [[ "${STRICT:-0}" -eq 1 ]]; then
    return 1
  fi
  return 0
}
