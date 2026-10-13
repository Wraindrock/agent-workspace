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
  state_exists "${1}" || die "no container named '${1}' is managed by this installer (try: install.sh list)"
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

ensure_image() {
  local ref="${1}"
  eng_image_exists "$ref" && return 0
  if [[ "${NO_PULL:-0}" -eq 1 ]]; then
    die "image ${ref} is not available locally and --no-pull was given"
  fi
  msg "pulling ${ref}"
  if [[ -n "${GUM_BIN:-}" ]]; then
    ui_spin "Pulling ${ref}" "$ENGINE_BIN" pull "$ref" || die "could not pull ${ref}"
  else
    "$ENGINE_BIN" pull "$ref" || die "could not pull ${ref}"
  fi
}

confirm() {
  [[ "${ASSUME_YES:-0}" -eq 1 ]] && return 0
  ui_confirm "${1}"
}

# --- create ----------------------------------------------------------------

# create_container_from NAME AGENT MODE WORKSPACE IMAGE_REF [DECLARED_IMAGE]
create_container_from() {
  local name="${1}" agent="${2}" mode="${3}" workspace="${4}" image_ref="${5}" declared="${6:-${5}}"
  local env_file volume
  env_file="$(env_file_for "$name")"
  volume="$(volume_name "$name")"

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
      args+=("$image_ref")
      run_engine "${args[@]}"
      if [[ "${DRY_RUN:-0}" -eq 0 ]]; then
        sleep 2
        if ! eng_container_running "$name"; then
          warn "container ${name} did not stay up; recent log lines:"
          "$ENGINE_BIN" logs --tail 20 "$name" 2>/dev/null || true
        fi
      fi
      ;;
    ephemeral)
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
      eargs+=("$image_ref" "$(agent_binary_of "$agent")")
      run_engine "${eargs[@]}"
      ;;
    *)
      die "unknown mode '${mode}' (expected persistent or ephemeral)"
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
  state_set "$name" CREATED "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  state_record_event "$name" "created from ${image_ref}"
}

# --- queries ---------------------------------------------------------------

cmd_list() {
  local names name agent mode engine status snapshots
  names="$(state_list)"
  if [[ -z "$names" ]]; then
    msg "no containers yet; create one with: install.sh create"
    return 0
  fi
  printf '%-18s %-10s %-11s %-7s %-9s %s\n' NAME AGENT MODE ENGINE STATE SNAPSHOTS
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
    printf '%-18s %-10s %-11s %-7s %-9s %s\n' "$name" "$agent" "$mode" "$engine" "$status" "$snapshots"
  done <<<"$names"
}

cmd_snapshots() {
  local name="${1}" ids id created label size
  require_container "$name"
  ids="$(snapshot_list "$name")"
  if [[ -z "$ids" ]]; then
    msg "no snapshots for ${name}"
    return 0
  fi
  printf '%-22s %-21s %-12s %s\n' ID CREATED LABEL SIZE
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    created="$(snapshot_get "$name" "$id" CREATED)"
    label="$(snapshot_get "$name" "$id" LABEL)"
    if [[ -f "$(snapshot_path "$name" "$id")/home.tar.gz" ]]; then
      size="$(du -h "$(snapshot_path "$name" "$id")/home.tar.gz" | cut -f1)"
    else
      size="-"
    fi
    printf '%-22s %-21s %-12s %s\n' "$id" "${created:-unknown}" "${label:--}" "$size"
  done <<<"$ids"
}

# --- lifecycle -------------------------------------------------------------

cmd_start() {
  local name="${1}"
  require_container "$name"
  state_engine "$name"
  if eng_container_running "$name"; then
    ok "${name} is already running"
    return 0
  fi
  eng_start "$name" >/dev/null
  ok "started ${name}"
}

cmd_stop() {
  local name="${1}"
  require_container "$name"
  state_engine "$name"
  eng_stop "$name"
  ok "stopped ${name}"
}

cmd_restart() {
  local name="${1}"
  require_container "$name"
  state_engine "$name"
  eng_stop "$name"
  eng_start "$name" >/dev/null
  ok "restarted ${name}"
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
    die "container ${name} was created in ephemeral mode and cannot be entered"
  fi
  if ! eng_container_running "$name"; then
    msg "starting ${name}"
    eng_start "$name" >/dev/null
    sleep 2
  fi
  if ! eng_container_running "$name"; then
    die "container ${name} is not running (try: install.sh logs ${name})"
  fi
  if [[ "${#}" -gt 0 ]]; then
    eng_exec "$name" "$@"
  else
    eng_exec "$name" "$(agent_binary_of "$(container_agent "$name")")"
  fi
}

# --- snapshots -------------------------------------------------------------

archive_home_volume() {
  local name="${1}" id="${2}" volume="" dir="" image=""
  volume="$(container_home_volume "$name")"
  dir="$(snapshot_path "$name" "$id")"
  image="$(snapshot_image "$name" "$id")"
  if ! eng_volume_exists "$volume"; then
    warn "home volume ${volume} does not exist; the snapshot holds the filesystem only"
    return 0
  fi
  if run_engine run --rm --entrypoint /usr/bin/tar --volume "${volume}:/data:ro" \
      --volume "${dir}:/backup$(engine_mount_suffix)" "$image" czf /backup/home.tar.gz -C /data .; then
    ok "archived the home volume into ${dir}/home.tar.gz"
  else
    warn "could not archive ${volume} (no tar in the image?); the snapshot holds the filesystem only"
  fi
}

restore_home_volume() {
  local name="${1}" id="${2}" volume="" dir="" image=""
  volume="$(container_home_volume "$name")"
  dir="$(snapshot_path "$name" "$id")"
  image="$(snapshot_image "$name" "$id")"
  if [[ ! -s "${dir}/home.tar.gz" ]]; then
    warn "snapshot ${id} has no home archive; the home volume is left as it is"
    return 0
  fi
  if ! eng_volume_exists "$volume"; then
    run_engine volume create "$volume" >/dev/null
  fi
  run_engine run --rm --entrypoint /usr/bin/tar --volume "${volume}:/data" \
    --volume "${dir}:/backup$(engine_mount_suffix)" "$image" xzf /backup/home.tar.gz -C /data
  ok "restored the home volume from snapshot ${id}"
}

cmd_snapshot() {
  local name="${1}" label="${2:-manual}" id="" ref="" dir=""
  require_container "$name"
  state_engine "$name"
  id="$(date -u +%Y%m%dT%H%M%SZ)"
  while [[ -e "$(snapshot_path "$name" "$id")" ]]; do
    id="${id}b"
  done
  ref="$(snapshot_image "$name" "$id")"
  dir="$(snapshot_path "$name" "$id")"
  install -d -m 0700 "$dir"
  if ! eng_commit "$name" "$ref"; then
    rm -rf "$dir"
    die "could not snapshot ${name}; is the container present? (try: install.sh recover ${name})"
  fi
  create_snapshot_meta "$name" "$id" "$label" "$ref"
  archive_home_volume "$name" "$id"
  state_set "$name" SNAPSHOT_LAST "$id"
  state_record_event "$name" "snapshot ${id} (${label})"
  snapshot_prune "$name" "${SNAPSHOT_KEEP:-5}"
  ok "snapshot ${id} of ${name} (${label})"
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
  [[ -n "$id" ]] || die "no snapshot available for ${name} (run: install.sh snapshot ${name})"
  [[ -f "$(snapshot_meta "$name" "$id")" ]] || die "snapshot ${id} not found for ${name}"
  printf '%s' "$id"
}

cmd_rollback() {
  local name="${1}" target="${2:-}" id="" ref="" agent="" mode="" workspace="" declared=""
  require_container "$name"
  state_engine "$name"
  id="$(resolve_snapshot "$name" "$target")"
  ref="$(snapshot_ref "$name" "$id")"
  if [[ "${DRY_RUN:-0}" -eq 0 ]] && ! eng_image_exists "$ref"; then
    die "snapshot image ${ref} is gone; snapshot ${id} cannot be restored"
  fi
  confirm "Replace container ${name} with snapshot ${id}?" || { warn "aborted"; return 0; }
  agent="$(container_agent "$name")"
  mode="$(container_mode "$name")"
  workspace="$(container_workspace "$name")"
  declared="$(snapshot_get "$name" "$id" IMAGE)"
  [[ -n "$declared" ]] || declared="$(state_get "$name" IMAGE)"
  eng_stop "$name"
  eng_remove "$name"
  restore_home_volume "$name" "$id"
  create_container_from "$name" "$agent" "$mode" "$workspace" "$ref" "$declared"
  state_set "$name" SNAPSHOT_LAST "$id"
  state_record_event "$name" "rolled back to ${id}"
  ok "rolled ${name} back to snapshot ${id}"
}

cmd_recover() {
  local name="${1}" id="" ref="" agent="" mode="" workspace="" declared="" image=""
  require_container "$name"
  state_engine "$name"

  if eng_container_exists "$name"; then
    if eng_container_running "$name"; then
      ok "${name} is running; nothing to recover"
      return 0
    fi
    eng_start "$name" >/dev/null
    sleep 2
    if eng_container_running "$name"; then
      ok "recovered ${name} (restarted the existing container)"
    else
      warn "${name} exists but does not stay up; check: install.sh logs ${name}"
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
    ok "recovered ${name} from snapshot ${id}"
  else
    image="$(container_run_image "$name")"
    [[ -n "$image" ]] || image="$IMAGE"
    ensure_image "$image"
    create_container_from "$name" "$agent" "$mode" "$workspace" "$image" "$(state_get "$name" IMAGE)"
    state_record_event "$name" "recovered from image ${image}"
    warn "no snapshot was available; ${name} was rebuilt from ${image} (the home volume is kept)"
  fi
}

cmd_fork() {
  local src="${1}" new="${2}" agent="${3:-}" mode="${4:-}" workspace="${5:-}" snap="${6:-}"
  local image="" src_volume="" new_volume="" engine=""
  require_container "$src"
  validate_name "$new" || die "invalid container name '${new}'"
  state_exists "$new" && die "container ${new} already exists"
  engine="$(state_get "$src" ENGINE)"
  use_engine "${engine:-$ENGINE}"
  agent="${agent:-$(container_agent "$src")}"
  agent_known "$agent" || die "unknown agent '${agent}'"
  mode="${mode:-$(container_mode "$src")}"
  workspace="${workspace:-$(default_workspace "$new")}"

  if [[ -n "$snap" ]]; then
    snap="$(resolve_snapshot "$src" "$snap")"
    image="$(snapshot_ref "$src" "$snap")"
  elif [[ "${FORK_LIVE:-0}" -eq 1 ]]; then
    image="$(container_run_image "$src")"
  else
    msg "snapshotting ${src} before the fork"
    cmd_snapshot "$src" "fork-source" >/dev/null
    snap="$(state_get "$src" SNAPSHOT_LAST)"
    image="$(snapshot_ref "$src" "$snap")"
  fi

  new_volume="$(volume_name "$new")"
  eng_volume_exists "$new_volume" && die "volume ${new_volume} already exists"
  run_engine volume create "$new_volume" >/dev/null

  if [[ -n "$snap" ]] && [[ -s "$(snapshot_path "$src" "$snap")/home.tar.gz" ]]; then
    msg "copying the home volume from snapshot ${snap}"
    run_engine run --rm --entrypoint /usr/bin/tar --volume "${new_volume}:/data" \
      --volume "$(snapshot_path "$src" "$snap"):/backup$(engine_mount_suffix)" "$image" \
      xzf /backup/home.tar.gz -C /data
  else
    src_volume="$(container_home_volume "$src")"
    if eng_volume_exists "$src_volume"; then
      msg "copying the live home volume ${src_volume}"
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
    warn "copied credentials from ${src}; review ${new_env} before use"
  fi

  create_container_from "$new" "$agent" "$mode" "$workspace" "$image" "$(state_get "$src" IMAGE)"
  state_set "$new" FORKED_FROM "$src"
  [[ -n "$snap" ]] && state_set "$new" FORKED_AT "$snap"
  ok "forked ${src} into ${new} (agent ${agent}, mode ${mode})"
}

cmd_upgrade() {
  local name="${1}" target="${2:-}" agent="" mode="" workspace=""
  require_container "$name"
  state_engine "$name"
  [[ -n "$target" ]] || target="$(state_get "$name" IMAGE)"
  [[ -n "$target" ]] || target="$IMAGE"
  ensure_image "$target"
  confirm "Upgrade ${name} to ${target}? A snapshot is taken first." || { warn "aborted"; return 0; }
  cmd_snapshot "$name" "pre-upgrade" >/dev/null
  agent="$(container_agent "$name")"
  mode="$(container_mode "$name")"
  workspace="$(container_workspace "$name")"
  eng_stop "$name"
  eng_remove "$name"
  create_container_from "$name" "$agent" "$mode" "$workspace" "$target" "$target"
  state_record_event "$name" "upgraded to ${target}"
  ok "upgraded ${name} to ${target}"
}

cmd_remove() {
  local name="${1}" id=""
  require_container "$name"
  state_engine "$name"
  confirm "Remove container ${name} and its volume?" || { warn "aborted"; return 0; }
  if eng_container_exists "$name"; then
    eng_stop "$name"
    eng_remove "$name"
  fi
  if [[ "${KEEP_VOLUME:-0}" -eq 1 ]]; then
    msg "kept volume $(container_home_volume "$name")"
  else
    eng_volume_remove "$(container_home_volume "$name")"
  fi
  rm -f "$(env_file_for "$name")"
  if [[ "${PURGE_SNAPSHOTS:-0}" -eq 1 ]]; then
    while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      snapshot_delete "$name" "$id"
    done < <(snapshot_list "$name")
    rm -rf "$(snapshot_root "$name")"
  else
    msg "kept snapshots for ${name} in $(snapshot_root "$name")"
  fi
  rm -rf "$(state_dir "$name")"
  ok "removed ${name}"
}

# --- host doctor -----------------------------------------------------------

cmd_doctor() {
  local problems=0 names name engine status image volume env_file id archive
  heading "Environment"
  local available
  available="$(detect_engines)"
  if [[ -z "$available" ]]; then
    report_bad "no container engine found (install podman or docker)"
    problems=$((problems + 1))
  else
    while IFS= read -r engine; do
      [[ -n "$engine" ]] || continue
      report_ok "engine available: $engine ($("$engine" --version 2>/dev/null | head -n 1))"
    done <<<"$available"
  fi
  report_ok "state directory: $DATA_HOME"
  report_ok "credentials directory: $CONF_HOME/containers"

  names="$(state_list)"
  if [[ -z "$names" ]]; then
    report_ok "no containers managed yet"
  fi
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    heading "Container ${name}"
    state_engine_soft "$name"
    engine="$(state_get "$name" ENGINE)"
    if ! command -v "$engine" >/dev/null 2>&1; then
      report_bad "engine ${engine} is not installed"
      problems=$((problems + 1))
    elif eng_container_exists "$name"; then
      status="$(eng_container_status "$name")"
      report_ok "container exists (${status})"
    else
      report_bad "container is missing; run: install.sh recover ${name}"
      problems=$((problems + 1))
    fi

    image="$(container_run_image "$name")"
    if command -v "$engine" >/dev/null 2>&1; then
      if eng_image_exists "$image"; then
        report_ok "image present: ${image}"
      else
        report_bad "image ${image} is not present; run: install.sh recover ${name}"
        problems=$((problems + 1))
      fi
    fi

    volume="$(container_home_volume "$name")"
    if [[ "$(container_mode "$name")" == "persistent" ]]; then
      if command -v "$engine" >/dev/null 2>&1 && eng_volume_exists "$volume"; then
        report_ok "home volume present: ${volume}"
      else
        report_bad "home volume ${volume} is missing"
        problems=$((problems + 1))
      fi
    fi

    env_file="$(env_file_for "$name")"
    if [[ -f "$env_file" ]]; then
      local mode_bits
      mode_bits="$(stat -c '%a' "$env_file" 2>/dev/null || printf 'unknown')"
      if [[ "$mode_bits" == "600" ]]; then
        report_ok "credentials ${env_file} (mode 600)"
      else
        report_bad "credentials ${env_file} have mode ${mode_bits}; expected 600"
        problems=$((problems + 1))
      fi
    fi

    while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      archive="$(snapshot_path "$name" "$id")/home.tar.gz"
      if [[ -f "$archive" ]]; then
        if tar -tzf "$archive" >/dev/null 2>&1; then
          report_ok "snapshot ${id} archive readable"
        else
          report_bad "snapshot ${id} archive is corrupt: ${archive}"
          problems=$((problems + 1))
        fi
      fi
    done < <(snapshot_list "$name")
  done <<<"$names"

  heading "Result"
  if [[ "$problems" -eq 0 ]]; then
    ok "doctor: no problems found"
    return 0
  fi
  warn "doctor: ${problems} problem(s) found"
  if [[ "${STRICT:-0}" -eq 1 ]]; then
    return 1
  fi
  return 0
}
