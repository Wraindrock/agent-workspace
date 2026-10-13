#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# agent-workspace build orchestrator.
#
# Contract:
#   1. the declarative overlay in system_files/ is copied verbatim to /
#   2. the runtime CLI in runtime/ is installed to /usr/bin and /usr/lib
#   3. every module under build_files/modules/<NN-name>/ runs in lexical
#      order, unless it is disabled in config/modules.conf or filtered out
#      by the IMAGE_MODULES build argument
#   4. each module leaves behind declarative state (enabled list, agent
#      list, versions) that the manifest module records in the image
# ---------------------------------------------------------------------------
set -euo pipefail

CTX_DIR="${CTX_DIR:-/ctx}"
BUILD_FILES="${CTX_DIR}/build_files"
export CTX_DIR BUILD_FILES
export STATE_DIR="${STATE_DIR:-/run/agent-workspace}"
export COMMON_LIB="${BUILD_FILES}/lib/common.sh"
export IMAGE_MODULES="${IMAGE_MODULES:-all}"

# shellcheck source=lib/common.sh
source "${COMMON_LIB}"

prepare_state() {
  mkdir -p "${STATE_DIR}"
  : > "${STATE_DIR}/modules.enabled"
  : > "${STATE_DIR}/agents.enabled"
  : > "${STATE_DIR}/agent-binary"
}

overlay_system_files() {
  [[ -d "${CTX_DIR}/system_files" ]] || return 0
  log "applying declarative overlay from system_files/"
  cp -avf "${CTX_DIR}/system_files/." /
}

install_runtime() {
  [[ -d "${CTX_DIR}/runtime" ]] || return 0
  log "installing agent-workspace runtime CLI"
  install -d -m 0755 /usr/bin /usr/lib/agent-workspace
  if [[ -d "${CTX_DIR}/runtime/lib" ]]; then
    cp -a "${CTX_DIR}/runtime/lib/." /usr/lib/agent-workspace/
    chmod -R 0755 /usr/lib/agent-workspace
  fi
  if [[ -d "${CTX_DIR}/runtime/bin" ]]; then
    install -m 0755 "${CTX_DIR}"/runtime/bin/* /usr/bin/
  fi
}

# module_is_enabled decides whether <name> runs for this build.
#   1. an explicit IMAGE_MODULES list (comma or space separated) wins
#   2. otherwise config/modules.conf may override the module default
#   3. otherwise the module's own MODULE_ENABLED_DEFAULT applies
module_is_enabled() {
  local name="$1" default="$2"
  local cfg="${CTX_DIR}/config/modules.conf"

  if [[ "${IMAGE_MODULES}" != "all" ]]; then
    local list=",${IMAGE_MODULES// /,},"
    [[ "$list" == *",${name},"* ]] && echo 1 || echo 0
    return 0
  fi

  if [[ -f "$cfg" ]]; then
    local key value line
    while IFS= read -r line; do
      line="${line%%#*}"
      [[ "$line" == *"="* ]] || continue
      key="${line%%=*}"
      value="${line#*=}"
      key="${key//[[:space:]]/}"
      value="${value//[[:space:]]/}"
      if [[ "$key" == "$name" ]]; then
        [[ "$value" == "1" ]] && echo 1 || echo 0
        return 0
      fi
    done < "$cfg"
  fi

  echo "$default"
}

run_modules() {
  local dir name enabled default
  for dir in "${BUILD_FILES}"/modules/*/; do
    [[ -d "$dir" ]] || continue
    name="$(basename "${dir%/}")"

    if [[ ! -f "${dir}module.env" || ! -x "${dir}install.sh" ]]; then
      warn "ignoring $name: a module needs an executable install.sh and a module.env"
      continue
    fi

    unset MODULE_NAME MODULE_DESCRIPTION MODULE_ENABLED_DEFAULT MODULE_REQUIRES
    # shellcheck disable=SC1090
    source "${dir}module.env"
    default="${MODULE_ENABLED_DEFAULT:-1}"
    enabled="$(module_is_enabled "$name" "$default")"

    if [[ "$enabled" != "1" ]]; then
      log "module ${name}: disabled, skipping"
      continue
    fi

    section "${name}: ${MODULE_DESCRIPTION:-no description}"
    (
      cd "$dir"
      MODULE_NAME="$name" MODULE_DIR="$dir" "${dir}install.sh"
    )
    echo "$name" >> "${STATE_DIR}/modules.enabled"
    ok "module ${name}: done"
  done
}

summarize() {
  local applied="${STATE_DIR}/modules.enabled" agents="${STATE_DIR}/agents.enabled"
  section "build summary"
  if [[ -s "${applied}" ]]; then
    log "modules applied: $(wc -l < "${applied}" | tr -d ' ')"
    sed 's/^/  - /' "${applied}"
  else
    log "modules applied: none"
  fi
  if [[ -s "${agents}" ]]; then
    log "agent harnesses installed:"
    sed 's/^/  - /' "${agents}"
  else
    log "agent harnesses installed: none"
  fi
}

main() {
  require_root
  require_command dnf5
  prepare_state
  overlay_system_files
  install_runtime
  run_modules
  summarize
  # /run is throwaway, but removing the state keeps the contract explicit:
  # nothing in the image may depend on build-time state.
  rm -rf "${STATE_DIR}"
}

main "$@"
