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
    snapshot_delete "$name" "$id"
  done <<<"$excess"
}

snapshot_delete() {
  local name="${1}" id="${2}" image dir
  image="$(snapshot_image "$name" "$id")"
  dir="$(snapshot_path "$name" "$id")"
  if eng_image_exists "$image"; then
    run_engine rmi --force "$image" >/dev/null 2>&1 || true
  fi
  rm -rf "${dir}"
}
