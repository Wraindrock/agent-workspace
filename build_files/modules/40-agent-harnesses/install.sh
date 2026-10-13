#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../lib/common.sh
source "${COMMON_LIB:?COMMON_LIB must point at build_files/lib/common.sh}"

AGENTS_DIR="${MODULE_DIR:?MODULE_DIR must be set}/agents"
AGENTS_CONF="${CTX_DIR:?CTX_DIR must be set}/config/agents.conf"

# agent_is_enabled mirrors module_is_enabled for the agent list, and lets a
# single build override the declarative default:
#   --build-arg AGENTS="claude-code,codex"
agent_is_enabled() {
  local name="$1" default="$2"
  local requested="${AGENTS:-all}"

  if [[ "$requested" != "all" ]]; then
    local list=",${requested// /,},"
    [[ "$list" == *",${name},"* ]] && echo 1 || echo 0
    return 0
  fi

  if [[ -f "$AGENTS_CONF" ]]; then
    local line key value
    while IFS= read -r line; do
      line="${line%%#*}"
      [[ "$line" == *"="* ]] || continue
      key="${line%%=*}"; value="${line#*=}"
      key="${key//[[:space:]]/}"; value="${value//[[:space:]]/}"
      if [[ "$key" == "$name" ]]; then
        [[ "$value" == "1" ]] && echo 1 || echo 0
        return 0
      fi
    done < "$AGENTS_CONF"
  fi

  echo "$default"
}

installed=0
for recipe in "${AGENTS_DIR}"/*.sh; do
  [[ -e "$recipe" ]] || continue
  agent="$(basename "${recipe%.sh}")"

  if [[ "$(agent_is_enabled "$agent" 0)" != "1" ]]; then
    log "agent ${agent}: disabled, skipping"
    continue
  fi

  section "agent ${agent}"
  # shellcheck disable=SC1090
  # shellcheck disable=SC1090
  (
    . "$recipe"
    install_agent
    record_value agent-binary "${agent} ${AGENT_BINARIES:-$agent}"
    # One tab-separated catalog line per harness: name, binaries, title, the
    # credential environment variables it understands. 80-manifest turns these
    # into manifest.json's agentCatalog, which the host installer (install.sh)
    # reads to offer exactly the agents this image ships.
    record_value agent-catalog "$(printf '%s\t%s\t%s\t%s' "$agent" "${AGENT_BINARIES:-$agent}" "${AGENT_TITLE:-$agent}" "${AGENT_ENV:-}")"
  )
  echo "$agent" >> "${STATE_DIR}/agents.enabled"
  ok "agent ${agent}: installed"
  installed=$((installed + 1))
done

if [[ "$installed" -eq 0 ]]; then
  warn "no agent harness was installed - check config/agents.conf"
fi
