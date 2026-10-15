#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# On-disk state: one directory per container plus its snapshots.
#
#   ${DATA_HOME}/containers/<name>/meta                 container metadata
#   ${DATA_HOME}/snapshots/<name>/<snapshot-id>/meta     snapshot metadata
#   ${DATA_HOME}/snapshots/<name>/<snapshot-id>/home.tar.gz
#
# Credentials never live here; they stay in ${CONF_HOME}/containers/<name>.env
# with mode 0600.
# ---------------------------------------------------------------------------

state_dir()     { printf '%s' "${DATA_HOME}/containers/${1}"; }
meta_path()     { printf '%s' "$(state_dir "${1}")/meta"; }
env_file_for()  { printf '%s' "${CONF_HOME}/containers/${1}.env"; }
volume_name()   { printf '%s' "${VOLUME_PREFIX}-${1}-home"; }

state_exists() { [[ -f "$(meta_path "$1")" ]]; }

state_get() {
  local path value
  path="$(meta_path "$1")"
  value=""
  if [[ -f "$path" ]]; then
    value="$(sed -n "s/^${2}=//p" "$path" | head -n 1)"
  fi
  printf '%s' "$value"
}

state_set() {
  local name="${1}" key="${2}" value="${3}" path dir tmp
  path="$(meta_path "$name")"
  dir="$(dirname "$path")"
  install -d -m 0700 "$dir"
  tmp="${path}.tmp.$$"
  if [[ -f "$path" ]]; then
    grep -v "^${key}=" "$path" >"$tmp" || true
  else
    : >"$tmp"
  fi
  printf '%s=%s\n' "$key" "$value" >>"$tmp"
  mv "$tmp" "$path"
}

state_list() {
  local dir
  dir="${DATA_HOME}/containers"
  [[ -d "$dir" ]] || return 0
  local entry
  for entry in "$dir"/*/meta; do
    [[ -f "$entry" ]] || continue
    basename "$(dirname "$entry")"
  done | sort
}

state_record_event() {
  local name="${1}" text="${2}" file
  file="$(meta_path "${name}")"
  [[ -f "$file" ]] || return 0
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$text" >>"${file}.history"
}

# --- snapshots -------------------------------------------------------------

snapshot_root()  { printf '%s' "${DATA_HOME}/snapshots/${1}"; }
snapshot_path()  { printf '%s' "$(snapshot_root "${1}")/${2}"; }
snapshot_meta()  { printf '%s' "$(snapshot_path "${1}" "${2}")/meta"; }
snapshot_image() { printf '%s' "agent-workspace/snapshot-${1}:${2}"; }

snapshot_get() {
  local path
  path="$(snapshot_meta "$1" "$2")"
  [[ -f "$path" ]] || return 0
  sed -n "s/^${3}=//p" "$path" | head -n 1
}

# snapshot_list prints snapshot ids oldest first, or names only metadata
snapshot_list() {
  local dir
  dir="$(snapshot_root "$1")"
  [[ -d "$dir" ]] || return 0
  local entry
  for entry in "$dir"/*/meta; do
    [[ -f "$entry" ]] || continue
    basename "$(dirname "$entry")"
  done | sort
}

snapshot_latest() {
  snapshot_list "$1" | tail -n 1
}

# snapshot_next_id NAME prints the id a new snapshot should take.
#
# Ids are second-granular and ordered as strings, so "an id nobody is using" is
# not enough: deleting a snapshot frees its id again, and the freed id can sort
# *before* one that still exists (`...Zb` is free while `...Zbb` is taken). A new
# snapshot has to sort strictly after everything that exists, or `--keep N`
# prunes the very snapshot it just took, and `latest`/`recover` resolve to an
# older one. The `b` suffix breaks ties inside a second by growing off whichever
# id is currently greatest, which also keeps ids monotonic if the clock steps
# backwards.
snapshot_next_id() {
  local name="${1}" id="" newest=""
  id="$(date -u +%Y%m%dT%H%M%SZ)"
  newest="$(snapshot_latest "$name")"
  if [[ -n "$newest" && ! "$id" > "$newest" ]]; then
    id="${newest}b"
  fi
  while [[ -e "$(snapshot_path "$name" "$id")" ]]; do
    id="${id}b"
  done
  printf '%s' "$id"
}

# snapshot_prune keeps the newest ${2} snapshots that are not protected.
snapshot_prune() {
  local name="${1}" keep="${2}" ids total excess id
  ids="$(snapshot_list "$name")"
  total="$(printf '%s\n' "$ids" | grep -c . || true)"
  if [[ "${total:-0}" -le "$keep" ]]; then
    return 0
  fi
  excess="$(printf '%s\n' "$ids" | head -n "$((total - keep))")"
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    # a kept snapshot reports why and returns non-zero; pruning the rest must
    # continue (and must not trip errexit in the caller)
    snapshot_delete "$name" "$id" || true
  done <<<"$excess"
}

# image_in_use IMAGE prints the first container that runs from IMAGE, or nothing
# when no container does. Snapshot images are shared: a fork or a rebuild keeps
# running from the very image another container's snapshot points at, so neither
# pruning nor remove may pull that image out from under it.
image_in_use() {
  local image="${1}" name=""
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if [[ "$(state_get "$name" RUN_IMAGE)" == "$image" ]]; then
      printf '%s' "$name"
      return 0
    fi
  done < <(state_list)
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if [[ "$(eng_container_image "$name" 2>/dev/null || true)" == "$image" ]]; then
      printf '%s' "$name"
      return 0
    fi
  done < <(eng_labeled_containers 2>/dev/null || true)
  return 1
}

# snapshot_delete NAME ID [force]
#
# Drops a snapshot record and the image it was committed to. An image a
# container still runs from is never deleted: pruning reports it and keeps the
# whole snapshot, because the image is the only handle the record has. force=1
# (install.sh remove --purge-snapshots) drops the record anyway, but still
# leaves the in-use image for the engine's own image prune.
snapshot_delete() {
  local name="${1}" id="${2}" force="${3:-0}" image="" dir="" holder=""
  image="$(snapshot_image "$name" "$id")"
  dir="$(snapshot_path "$name" "$id")"
  if eng_image_exists "$image"; then
    holder="$(image_in_use "$image")" || holder=""
  fi
  if [[ -n "$holder" ]]; then
    if [[ "$force" -eq 1 ]]; then
      warn_k kept_image_in_use "${image}" "${holder}"
      rm -rf "${dir}"
      return 0
    fi
    warn_k kept_snapshot_in_use "${id}" "${name}" "${holder}" "${image}"
    return 1
  fi
  if eng_image_exists "$image"; then
    if ! run_engine rmi "$image" >/dev/null 2>&1; then
      warn_k image_undeletable "${image}" "${id}"
      return 1
    fi
  fi
  rm -rf "${dir}"
  return 0
}
