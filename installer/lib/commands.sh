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
    # Engine binary is read by the backend file loaded below rather than here;
    # exporting it keeps that cross-file use (and shellcheck) honest.
    ENGINE_BIN="$engine"
    export ENGINE_BIN
    # Soft path: an instance recorded by a backend this tree no longer ships is
    # still worth reporting on, so a missing implementation file is not fatal.
    if [[ -r "${BACKEND_DIR}/backend-${engine}.sh" ]]; then
      backend_load "$engine"
    fi
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
      eng_pull "$ref"
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
    eng_pull "$ref"
    return 0
  fi
  refresh_image "$ref"
}

pull_image() {
  # A dry run does not touch the registry, but eng_pull still says what a real
  # run would do, so the spinner is bypassed rather than swallowing that line.
  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    eng_pull "$1"
    return 0
  fi
  if [[ -n "${GUM_BIN:-}" ]]; then
    ui_spin "$(tf pulling "${1}")" eng_pull "$1"
  else
    eng_pull "$1"
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
  local env_file volume web web_port publish_port=""
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

  if [[ "$web" == "1" && -n "$web_port" ]]; then
    publish_port="$web_port"
  fi

  case "$mode" in
    persistent)
      eng_volume_exists "$volume" || eng_volume_create "$volume" >/dev/null
      eng_create_persistent "$name" "$image_ref" "$volume" "$env_file" "$publish_port" "$agent"
      if [[ "${DRY_RUN:-0}" -eq 0 ]]; then
        # Wait for the container to reach "running" instead of trusting that it
        # did: a container that exits on start (a dangling /home, an image whose
        # command is not systemd) used to be reported as created. The wait is a
        # liveness probe, not a fixed sleep, and it is bounded.
        local waited=0 timeout="${CONTAINER_READY_TIMEOUT:-30}"
        until eng_container_running "$name"; do
          if [[ "${waited}" -ge "${timeout}" ]]; then
            warn_k err_did_not_stay_up "${name}"
            eng_logs "$name" 20 || true
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
      eng_create_ephemeral "$name" "$image_ref" "$env_file" "$agent" "$(agent_launch_command "$agent")"
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
  local name="${1}" follow=0
  require_container "$name"
  state_engine "$name"
  if [[ "${LOGS_FOLLOW:-0}" -eq 1 ]]; then
    follow=1
  fi
  eng_logs "$name" "${LOGS_TAIL:-50}" "$follow"
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
  eng_exec_test "$name" /bin/bash -c "exec 3<>/dev/tcp/127.0.0.1/${port}"
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
    eng_exec_background "$name" "$AGENT_USER" \
      "install -d -m 0700 ${log_dir} && : >${log_file} && exec ${webcmd} >>${log_file} 2>&1"
  fi

  token=""
  for ((i = 0; i < 20; i++)); do
    token="$(eng_exec_capture "$name" /bin/bash -c "grep -o 'token=[A-Za-z0-9_-]*' ${log_file} 2>/dev/null | tail -n 1 | cut -d= -f2")"
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
    if eng_exec_test "$name" /bin/bash -c 'test -f /var/lib/agent-workspace/.provisioned'; then
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
    eng_exec_background "$name" "$AGENT_USER" "$(agent_web_command "$agent")"
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
  if eng_volume_archive "$volume" "$dir" "$image"; then
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
  eng_volume_restore_archive "$volume" "${dir}/home.tar.gz" "$image"
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
  workspace="${workspace:-}"

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
  eng_volume_create "$new_volume" >/dev/null

  if [[ -n "$snap" ]] && [[ -s "$(snapshot_path "$src" "$snap")/home.tar.gz" ]]; then
    msg_k forking_copy_snap "${snap}"
    eng_volume_restore_archive "$new_volume" "$(snapshot_path "$src" "$snap")/home.tar.gz" "$image"
  else
    src_volume="$(container_home_volume "$src")"
    if eng_volume_exists "$src_volume"; then
      msg_k forking_copy_live "${src_volume}"
      eng_volume_clone "$src_volume" "$new_volume" "$image"
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
  local name="${1}" id="" engine_was=""
  require_container "$name"
  # The recorded backend is not needed to leave: removing an instance must still
  # work when the backend that created it is gone from this host, otherwise a
  # broken engine leaves state nobody can clean up. When it is present, use it.
  engine_was="$(state_get "$name" ENGINE)"
  command -v "$engine_was" >/dev/null 2>&1 && state_engine "$name"
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

# --- backup, restore, rescue ----------------------------------------------
#
# Data lives inside the instance, so the only way to get it out (or back in) is
# through the engine. Backup bundles the home volume with a manifest and proves
# the archive readable before it keeps it; restore proves the source readable
# and takes a safety clone before it overwrites anything; rescue is the door for
# a locked-out account or a broken config. All three print counts, not "done".

# archive_has_member MEMBERS MEMBER succeeds when MEMBER is one of the tar
# members (exact, not a substring: `home` must not match `home.tar.gz`).
archive_has_member() {
  local members="$1" member="$2"
  case $'\n'"${members}"$'\n' in
    *$'\n'"${member}"$'\n'*) return 0 ;;
  esac
  return 1
}

# archive_missing_members MEMBERS prints what a backup/restore archive lacks,
# as a comma-separated list (empty means it has the required members). The home
# data may be listed as `home/` by tar; accept the plain directory spelling too.
archive_missing_members() {
  local members="$1" missing=""
  archive_has_member "$members" "manifest.txt" || missing="manifest.txt"
  if ! archive_has_member "$members" "home" &&
     ! archive_has_member "$members" "home/" &&
     ! archive_has_member "$members" "./home" &&
     ! archive_has_member "$members" "./home/"; then
    missing="${missing:+${missing}, }home/"
  fi
  printf '%s' "$missing"
}

archive_member_count() {
  local archive="$1" members=""
  members="$(tar -tzf "$archive" 2>/dev/null || true)"
  if [[ -z "$members" ]]; then
    printf '0'
    return 0
  fi
  printf '%s\n' "$members" | wc -l | tr -d ' '
}

# cmd_backup NAME [--to FILE]: archive the instance's home storage plus a
# manifest. The destination is never overwritten, and the archive is verified
# before it is moved into place: a partial file that looks like a backup is
# worse than a clear failure.
cmd_backup() {
  local name="${1}" to="${2:-}" volume image dest stage members missing count digest
  require_container "$name"
  state_engine "$name"
  volume="$(container_home_volume "$name")"
  image="$(container_run_image "$name")"
  dest="${to:-agent-workspace-backup-${name}-$(date -u +%Y%m%d-%H%M%S).tar.gz}"
  if [[ -e "$dest" ]]; then
    die_k backup_exists "$dest"
  fi
  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    msg_k dry_backup "$name" "$dest"
    msg_k dry_backup_members
    return 0
  fi

  stage="$(mktemp -d)"
  install -d -m 0700 "$stage/raw" "$stage/root/home"
  if ! eng_volume_exists "$volume"; then
    rm -rf "$stage"
    die_k backup_missing_volume "$volume" "$name"
  fi
  if ! eng_volume_archive "$volume" "$stage/raw" "$image"; then
    rm -rf "$stage"
    die_k backup_unreadable "$volume"
  fi
  if ! home_archive_ok "$stage/raw/home.tar.gz"; then
    rm -rf "$stage"
    die_k backup_unreadable "$volume"
  fi
  if ! tar xzf "$stage/raw/home.tar.gz" -C "$stage/root/home" 2>/dev/null; then
    rm -rf "$stage"
    die_k backup_unreadable "$volume"
  fi

  digest="$(eng_image_id "$image" 2>/dev/null || true)"
  {
    printf 'FORMAT=1\n'
    printf 'CONTAINER=%s\n' "$name"
    printf 'AGENT=%s\n' "$(container_agent "$name")"
    printf 'MODE=%s\n' "$(container_mode "$name")"
    printf 'ENGINE=%s\n' "$ENGINE"
    printf 'IMAGE=%s\n' "$(state_get "$name" IMAGE)"
    printf 'RUN_IMAGE=%s\n' "$image"
    printf 'DIGEST=%s\n' "${digest:-unknown}"
    printf 'CREATED=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'DATA=home\n'
    printf 'MEMBERS=manifest.txt home\n'
  } >"$stage/root/manifest.txt"
  chmod 0600 "$stage/root/manifest.txt"

  if ! (umask 077; tar czf "${dest}.partial" -C "$stage/root" manifest.txt home 2>/dev/null); then
    rm -f "${dest}.partial"
    rm -rf "$stage"
    die_k backup_unreadable "$dest"
  fi
  members="$(tar -tzf "${dest}.partial" 2>/dev/null || true)"
  missing="$(archive_missing_members "$members")"
  if [[ -n "$missing" ]]; then
    rm -f "${dest}.partial"
    rm -rf "$stage"
    die_k backup_unverified "${dest}.partial" "$missing"
  fi
  if [[ -e "$dest" ]]; then
    rm -f "${dest}.partial"
    rm -rf "$stage"
    die_k backup_exists "$dest"
  fi
  mv "${dest}.partial" "$dest"
  chmod 0600 "$dest" 2>/dev/null || true
  count="$(archive_member_count "$dest")"
  rm -rf "$stage"
  ok_k backup_written "$dest" "$count"
}

# cmd_restore NAME ARCHIVE: validate first, never overwrite a running instance,
# and clone the current volume before replacing it (unless --skip-safety).
cmd_restore() {
  local name="${1}" archive="${2}" volume image pre members missing count stamp bump target safety_count
  require_container "$name"
  state_engine "$name"
  volume="$(container_home_volume "$name")"
  image="$(container_run_image "$name")"

  if [[ ! -f "$archive" ]]; then
    die_k restore_missing_file "$archive"
  fi
  if ! tar -tzf "$archive" >/dev/null 2>&1; then
    die_k restore_unreadable "$archive"
  fi
  members="$(tar -tzf "$archive" 2>/dev/null || true)"
  missing="$(archive_missing_members "$members")"
  if [[ -n "$missing" ]]; then
    die_k restore_bad_archive "$archive" "$missing"
  fi
  if eng_container_running "$name"; then
    die_k restore_running "$name" "$name"
  fi

  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    msg_k dry_restore "$name" "$archive"
    if [[ "${SKIP_SAFETY:-0}" -eq 1 ]]; then
      msg_k dry_restore_skip
    else
      msg_k dry_restore_clone
    fi
    return 0
  fi

  target="$(mktemp -d)"
  tar xzf "$archive" -C "$target" manifest.txt home 2>/dev/null
  if [[ ! -d "$target/home" ]]; then
    rm -rf "$target"
    die_k restore_bad_archive "$archive" "home/"
  fi
  if ! tar czf "$target/home.tar.gz" -C "$target/home" . 2>/dev/null; then
    rm -rf "$target"
    die_k restore_bad_archive "$archive" "home/"
  fi
  if ! home_archive_ok "$target/home.tar.gz"; then
    rm -rf "$target"
    die_k restore_bad_archive "$archive" "home/"
  fi
  count="$(tar -tzf "$target/home.tar.gz" 2>/dev/null | wc -l || true)"
  count="$((count + 0))"

  if [[ "${SKIP_SAFETY:-0}" -eq 1 ]]; then
    warn_k restore_safety_skipped "$name"
  else
    stamp="$(date -u +%Y%m%d-%H%M%S)"
    pre="$(volume_name "$name")-pre-restore-${stamp}"
    bump=1
    while eng_volume_exists "$pre"; do
      pre="$(volume_name "$name")-pre-restore-${stamp}-${bump}"
      bump=$((bump + 1))
    done
    if ! eng_volume_clone "$volume" "$pre" "$image"; then
      rm -rf "$target"
      die_k restore_safety_failed "$pre"
    fi
    safety_count="0"
    install -d -m 0700 "$target/safety"
    if eng_volume_archive "$pre" "$target/safety" "$image" 2>/dev/null; then
      safety_count="$(archive_member_count "$target/safety/home.tar.gz")"
    fi
    rm -rf "$target/safety"
    ok_k restore_safety "$pre" "$safety_count"
  fi

  if ! eng_volume_restore_archive "$volume" "$target/home.tar.gz" "$image"; then
    rm -rf "$target"
    die_k restore_failed "$volume"
  fi
  rm -rf "$target"
  if ! eng_volume_exists "$volume"; then
    die_k restore_verify_failed "$volume"
  fi
  ok_k restore_done "$volume" "$count"
}

# cmd_rescue NAME [--copy PATH]: get back in or get data out. Starting a stopped
# instance is part of the job (that is what "locked out" looks like), but the
# command never changes the instance's configuration.
cmd_rescue() {
  local name="${1}" rel="" volume image stage target waited=0 timeout=30
  require_container "$name"
  state_engine "$name"
  volume="$(container_home_volume "$name")"
  image="$(container_run_image "$name")"

  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    msg_k dry_rescue "$name" "${OPT_COPY:-}"
    return 0
  fi

  if ! eng_container_running "$name"; then
    msg_k rescue_starting "$name"
    eng_start "$name" >/dev/null 2>&1 || true
    timeout="${CONTAINER_READY_TIMEOUT:-30}"
    until eng_container_running "$name"; do
      if [[ "$waited" -ge "$timeout" ]]; then
        die_k rescue_start_failed "$name"
      fi
      sleep 1
      waited=$((waited + 1))
    done
    msg_k rescue_started "$name"
  fi

  if [[ -z "${OPT_COPY:-}" ]]; then
    if [[ ! -t 0 ]] || [[ ! -t 1 ]]; then
      die_k rescue_no_tty
    fi
    msg_k rescue_shell "$name"
    eng_exec_root "$name" /bin/bash --login
    return 0
  fi

  rel="${OPT_COPY}"
  if [[ "$rel" == "/home/${AGENT_USER}/"* ]]; then
    rel="${rel#"/home/${AGENT_USER}/"}"
  fi
  if [[ -z "$rel" ]] || [[ "$rel" == /* ]]; then
    die_k rescue_outside "${OPT_COPY}"
  fi
  case "/${rel}/" in
    *"/../"*|*"/./"*) die_k rescue_outside "${OPT_COPY}" ;;
  esac
  if ! eng_exec_test "$name" test -e "/home/${AGENT_USER}/${rel}"; then
    die_k rescue_copy_missing "$name" "/home/${AGENT_USER}/${rel}"
  fi

  stage="$(mktemp -d)"
  if ! eng_volume_export_path "$volume" "$rel" "$stage" "$image"; then
    rm -rf "$stage"
    die_k rescue_copy_failed "${OPT_COPY}"
  fi
  if [[ ! -s "$stage/rescue.tar.gz" ]] || ! tar -tzf "$stage/rescue.tar.gz" >/dev/null 2>&1; then
    rm -rf "$stage"
    die_k rescue_copy_failed "${OPT_COPY}"
  fi
  if ! tar xzf "$stage/rescue.tar.gz" -C "$PWD" 2>/dev/null; then
    rm -rf "$stage"
    die_k rescue_copy_failed "${OPT_COPY}"
  fi
  rm -rf "$stage"
  target="${PWD}/${rel}"
  if [[ ! -e "$target" ]]; then
    die_k rescue_copy_failed "${OPT_COPY}"
  fi
  ok_k rescue_copied "$target"
}
# --- host doctor -----------------------------------------------------------

cmd_doctor() {
  local problems=0 names name engine status image volume env_file id archive web mapped
  heading_k head_environment
  local available current_backend
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
  # Every backend, not just the installed ones: a host with nothing installed is
  # where the list is the answer, and it has to say which ones are gated or not
  # implemented yet rather than leaving them out.
  backend_availability
  current_backend="$(state_preference)"
  if [[ -n "$current_backend" ]]; then
    report_ok_k doc_backend_pref "${current_backend}"
  else
    # A notice, not a problem: a host that only runs `doctor` before deciding is
    # healthy, and counting this would make a clean host report a problem.
    warn_k backend_none_remembered
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

# cmd_backend [set NAME] shows or changes the remembered backend choice. It is
# the only part of the installer that runs without a backend: a host that has
# none is exactly where "which one do you want?" has to be answerable
# (docs/backend-model.md: the remembered choice is what prints the list).
cmd_backend() {
  local action="${1:-}" name="${2:-}" current=""
  case "$action" in
    "") ;;
    set)
      if [[ -z "$name" ]]; then
        die_k err_backend_set_needs_name
      fi
      if ! validate_backend "$name"; then
        die_k err_backend_unknown "${name}"
      fi
      if backend_gated "$name"; then
        die_backend_gated "$name"
      fi
      if backend_unimplemented "$name"; then
        die_backend_unimplemented "$name"
      fi
      state_remember "$name"
      ok_k backend_pref_set "${name}" "$(preference_path)"
      return 0
      ;;
    *) die_k err_backend_subcommand "${action}" ;;
  esac

  current="$(state_preference)"
  if [[ -z "$current" ]]; then
    warn_k backend_none_remembered
  else
    msg_k backend_remembered "${current}"
  fi
  backend_list
}

# backend_availability prints, for every backend the model knows, whether it is
# usable here. doctor prints the same list even when no backend is installed,
# which is when "which of these would work?" matters most; a backend that is
# installed but whose daemon is not answering says so rather than reading as a
# plain "not installed".
backend_availability() {
  local name state=""
  # for, not `while read`, so the list still prints when stdin is /dev/null.
  for name in $(backend_all_names); do
    if backend_unimplemented "$name"; then
      state="$(tf backend_unimplemented)"
    elif backend_gated "$name"; then
      state="$(tf backend_gated)"
    elif ! backend_installed "$name"; then
      state="$(tf backend_unavailable)"
    elif ! backend_ready "$name"; then
      state="$(tf backend_not_ready_state "$(backend_not_ready_hint "$name")")"
    else
      state="$(tf backend_available)"
    fi
    printf '  %-8s %s\n' "$name" "$state"
  done
}

# --- in-instance root ------------------------------------------------------
#
# Whether the agent user may become root inside the instance is a switch the
# user flips at any time, not something fixed at create time. Its state lives
# inside the instance: /etc/sudoers.d/agent-workspace is what was asked for and
# the sudo probe is what is actually granted, so this command reports both and
# never infers one from the other. The host keeps only the password a human may
# need to log in with, next to the other credentials.
#
# The switch is read by running `sudo -n true` as the agent inside the running
# instance. Reading the sudoers file is not evidence: it can be shadowed,
# edited or stale, and an instance that is stopped cannot answer at all.

root_sudoers_path() { printf '%s' "/etc/sudoers.d/agent-workspace"; }
root_sudoers_tmp()  { printf '%s' "/etc/sudoers.d/.agent-workspace.tmp"; }
root_rule_line()    { printf '%s ALL=(ALL) NOPASSWD: ALL' "${AGENT_USER}"; }

# in_instance_root_live NAME: succeeds when `sudo -n true` succeeds as the agent.
# `su` rather than an exec-user flag keeps this backend-neutral and matches what
# a real login would experience (including a locked account).
in_instance_root_live() {
  local name="${1}"
  eng_exec_test "$name" su -s /bin/sh -c 'sudo -n true' "${AGENT_USER}"
}

in_instance_sudoers_present() {
  local name="${1}"
  eng_exec_test "$name" test -f "$(root_sudoers_path)"
}

# in_instance_password NAME PASSWORD: chpasswd reads user:password from stdin,
# so the password never appears in the engine command line, in a log or in the
# process list.
in_instance_password() {
  local name="${1}" password="${2}"
  printf '%s:%s\n' "${AGENT_USER}" "$password" | eng_exec_test "$name" chpasswd
}

# root_random_password: 32 hex characters (128 bits) straight from /dev/urandom.
root_random_password() {
  od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
}

# write_root_credentials NAME PASSWORD: keep the in-instance root password
# host-side, 0600, in the credentials tree. Written to a same-directory temp
# file and renamed, like the remembered backend, so a reader never sees half.
write_root_credentials() {
  local name="${1}" password="${2}" path dir tmp
  path="$(root_credentials_path "$name")"
  dir="$(dirname "$path")"
  install -d -m 0700 "$dir"
  tmp="$(mktemp "${dir}/.root.XXXXXX")"
  chmod 0600 "$tmp"
  printf '%s\n' "$password" >"$tmp"
  mv "$tmp" "$path"
}

# remove_root_credentials NAME: succeeds when a file was actually removed, so
# the caller can report a count instead of a vague "done".
remove_root_credentials() {
  local path
  path="$(root_credentials_path "$1")"
  [[ -f "$path" ]] || return 1
  rm -f "$path"
}

# root_plan NAME on|off: the dry-run narrative. A dry run must not write a real
# password file or pretend the live probe answered, so the steps print instead
# of running.
root_plan() {
  local name="${1}" mode="${2}"
  if [[ "$mode" == on ]]; then
    eng_exec_test "$name" install -d -m 0750 /etc/sudoers.d
    printf '%s\n' "$(root_rule_line)" | eng_exec_test "$name" /bin/sh -c "cat > $(root_sudoers_tmp)"
    eng_exec_test "$name" visudo -cf "$(root_sudoers_tmp)"
    eng_exec_test "$name" install -m 0440 "$(root_sudoers_tmp)" "$(root_sudoers_path)"
    eng_exec_test "$name" rm -f "$(root_sudoers_tmp)"
    printf 'pw\n' | eng_exec_test "$name" chpasswd
    eng_exec_test "$name" passwd -u "${AGENT_USER}"
  else
    eng_exec_test "$name" rm -f "$(root_sudoers_path)"
    printf 'pw\n' | eng_exec_test "$name" chpasswd
    eng_exec_test "$name" passwd -l "${AGENT_USER}"
  fi
  msg_k root_plan "$name"
}

root_status() {
  local name="${1}" live=0 present=0
  state_engine "$name"
  if ! eng_container_running "$name"; then
    die_k root_status_stopped "$name" "install.sh start $name"
  fi
  if in_instance_root_live "$name"; then live=1; fi
  if in_instance_sudoers_present "$name"; then present=1; fi
  if [[ "$live" -eq 1 ]]; then
    ok_k root_status_on "$name" "${AGENT_USER}"
  else
    ok_k root_status_off "$name" "${AGENT_USER}"
  fi
  if [[ "$present" -eq 1 ]]; then
    msg_k root_sudoers_present
  else
    msg_k root_sudoers_absent
  fi
  # The probe and the file can disagree; say so and name the command that
  # repairs each direction instead of silently picking a winner.
  if [[ "$live" -eq 1 && "$present" -eq 0 ]]; then
    warn_k root_status_mismatch_on "$name"
  elif [[ "$live" -eq 0 && "$present" -eq 1 ]]; then
    warn_k root_status_mismatch_off "$name"
  fi
}

root_on() {
  local name="${1}" password=""
  state_engine "$name"
  eng_container_running "$name" || die_k err_start_it "$name" "$name"
  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    root_plan "$name" on
    return 0
  fi
  if in_instance_root_live "$name" && in_instance_sudoers_present "$name"; then
    ok_k root_already_on "$name"
    return 0
  fi
  eng_exec_test "$name" install -d -m 0750 /etc/sudoers.d \
    || die_k root_exec_failed "$name" "$name"
  printf '%s\n' "$(root_rule_line)" | eng_exec_test "$name" /bin/sh -c "cat > $(root_sudoers_tmp)" \
    || die_k root_exec_failed "$name" "$name"
  if ! eng_exec_test "$name" visudo -cf "$(root_sudoers_tmp)"; then
    # A broken rule must never become live: drop the candidate and stop.
    eng_exec_test "$name" rm -f "$(root_sudoers_tmp)" || true
    die_k root_sudoers_invalid "$name" "$name"
  fi
  eng_exec_test "$name" install -m 0440 "$(root_sudoers_tmp)" "$(root_sudoers_path)" \
    || die_k root_exec_failed "$name" "$name"
  eng_exec_test "$name" rm -f "$(root_sudoers_tmp)" || true
  password="$(root_random_password)"
  in_instance_password "$name" "$password" || die_k root_password_failed "$name" "$name"
  # chpasswd rewrites the password field, which clears a lock; unlock anyway so
  # the account is usable for a real login, not only for passwordless sudo.
  eng_exec_test "$name" passwd -u "${AGENT_USER}" || true
  write_root_credentials "$name" "$password"
  if ! in_instance_root_live "$name"; then
    die_k root_verify_failed "$name" "$name"
  fi
  ok_k root_on_done "$name" "$(root_credentials_path "$name")"
}

root_off() {
  local name="${1}" password="" removed=0
  state_engine "$name"
  eng_container_running "$name" || die_k err_start_it "$name" "$name"
  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    root_plan "$name" off
    return 0
  fi
  if ! in_instance_root_live "$name" && ! in_instance_sudoers_present "$name"; then
    if remove_root_credentials "$name"; then removed=1; fi
    ok_k root_already_off "$name"
    msg_k root_creds_removed "$removed"
    return 0
  fi
  eng_exec_test "$name" rm -f "$(root_sudoers_path)" || die_k root_exec_failed "$name" "$name"
  password="$(root_random_password)"
  in_instance_password "$name" "$password" || die_k root_password_failed "$name" "$name"
  eng_exec_test "$name" passwd -l "${AGENT_USER}" || true
  if remove_root_credentials "$name"; then removed=1; fi
  if in_instance_root_live "$name"; then
    die_k root_off_failed "$name" "$name"
  fi
  ok_k root_off_done "$name"
  msg_k root_creds_removed "$removed"
  msg_k root_off_running_note
}

cmd_root() {
  local name="${1:-}" action="${2:-status}"
  require_container "$name"
  case "$action" in
    on) root_on "$name" ;;
    off) root_off "$name" ;;
    status) root_status "$name" ;;
    *) die_k root_choice "$action" ;;
  esac
}
