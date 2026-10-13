#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# The agent catalogue.
#
# Recipes baked into the image are published in
# /usr/share/agent-workspace/manifest.json as agentCatalog; the installer reads
# them through a throwaway container so the host needs no jq. When the manifest
# cannot be read the built-in table below is used.
# ---------------------------------------------------------------------------

declare -A AGENT_BINARIES=()
declare -A AGENT_TITLES=()
declare -A AGENT_ENVS=()
AGENT_ORDER=()

add_agent() {
  local name="${1}" binaries="${2}" title="${3}" envs="${4:-}"
  if [[ -z "${AGENT_BINARIES[${name}]:-}" ]]; then
    AGENT_ORDER+=("${name}")
  fi
  AGENT_BINARIES["${name}"]="$binaries"
  AGENT_TITLES["${name}"]="$title"
  AGENT_ENVS["${name}"]="$envs"
}

builtin_agents() {
  add_agent dsh dsh "DSH (DeepSeek Harness)" "DEEPSEEK_API_KEY"
  add_agent opencode opencode "OpenCode" "DEEPSEEK_API_KEY"
}

agent_known() { [[ -n "${AGENT_BINARIES[${1}]:-}" ]]; }
agent_names() { local name; for name in "${AGENT_ORDER[@]}"; do printf '%s\n' "$name"; done; }
agent_binary_of() { local binaries="${AGENT_BINARIES[${1}]:-}"; printf '%s' "${binaries%% *}"; }
agent_title_of()  { printf '%s' "${AGENT_TITLES[${1}]:-${1}}"; }
agent_envs_for()  { printf '%s' "${AGENT_ENVS[${1}]:-}"; }

# image_agents prints "name<TAB>binaries<TAB>title<TAB>env" for the image.
image_agents() {
  [[ -n "${ENGINE_BIN:-}" ]] || return 0
  [[ -n "${IMAGE:-}" ]] || return 0
  eng_image_exists "$IMAGE" || return 0
  "$ENGINE_BIN" run --rm --entrypoint /usr/bin/jq "$IMAGE" -r '
    (.agentCatalog // {}) | to_entries[] |
    [.key, ((.value.binaries // []) | join(" ")), (.value.title // .key), ((.value.env // []) | join(" "))] | @tsv
  ' /usr/share/agent-workspace/manifest.json 2>/dev/null || true
}

load_agents() {
  AGENT_ORDER=()
  AGENT_BINARIES=()
  AGENT_TITLES=()
  AGENT_ENVS=()
  builtin_agents
  local name binaries title envs
  while IFS=$'\t' read -r name binaries title envs; do
    [[ -n "$name" ]] || continue
    add_agent "$name" "${binaries:-$name}" "${title:-$name}" "$envs"
  done < <(image_agents)
}
