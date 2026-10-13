#!/usr/bin/env bash
# version / manifest / modules / agents

cmd_version() {
  load_env
  printf 'agent-workspace\n'
  printf '  image     : %s\n' "$(image_ref)"
  printf '  version   : %s\n' "$(image_version)"
  printf '  base      : %s\n' "${AGENT_WORKSPACE_BASE_IMAGE:-unknown}"
  printf '  fedora    : %s\n' "${AGENT_WORKSPACE_FEDORA:-unknown}"
  printf '  git sha   : %s\n' "${AGENT_WORKSPACE_GIT_SHA:-unknown}"
  printf '  built     : %s\n' "${AGENT_WORKSPACE_BUILD_DATE:-unknown}"
  printf '  license   : MIT\n'
  if [[ -r "$MANIFEST_PATH" ]]; then
    printf '  manifest  : %s\n' "$MANIFEST_PATH"
  else
    printf '  manifest  : not present (unexpected for a released image)\n'
  fi
}

cmd_manifest() {
  [[ -r "$MANIFEST_PATH" ]] || die "no manifest at $MANIFEST_PATH"
  if [[ "${1:-}" == "--json" ]] || ! have jq; then
    cat "$MANIFEST_PATH"
  else
    jq . "$MANIFEST_PATH"
  fi
}

cmd_modules() {
  if [[ -r "$MANIFEST_PATH" ]] && have jq; then
    jq -r '.modules[]' "$MANIFEST_PATH"
  elif [[ -r /usr/share/agent-workspace/modules.txt ]]; then
    cat /usr/share/agent-workspace/modules.txt
  else
    die "no module record found in this image"
  fi
}

cmd_agents() {
  local installed=()
  if [[ -r "$MANIFEST_PATH" ]] && have jq; then
    mapfile -t installed < <(jq -r '.agents[]?' "$MANIFEST_PATH")
  fi
  if [[ "${#installed[@]}" -eq 0 ]]; then
    log "no agent harness is baked into this image"
    return 0
  fi
  local agent binary
  for agent in "${installed[@]}"; do
    binary="${agent%%-cli}"
    if have "$binary"; then
      ok "$agent -> $(command -v "$binary")"
    else
      warn "$agent is declared in the manifest but its binary is missing"
    fi
  done
}
