#!/usr/bin/env bash
# Runtime status of the sandbox container.

cmd_status() {
  load_env

  local mode="process"
  is_container && mode="container"

  local user="${AGENT_WORKSPACE_USER:-agent}"
  local agents=""
  if [[ -r "$MANIFEST_PATH" ]] && have jq; then
    agents="$(jq -r '.agents[]?' "$MANIFEST_PATH" 2>/dev/null | tr '\n' ' ')"
  fi

  if [[ "${1:-}" == "--json" ]] && have jq; then
    jq -n --arg image "$(image_ref)" --arg version "$(image_version)" \
      --arg mode "$mode" --arg user "$user" --arg fedora "${AGENT_WORKSPACE_FEDORA:-unknown}" \
      '{image: $image, version: $version, mode: $mode, agentUser: $user, fedora: $fedora}'
    return 0
  fi

  printf 'image   : %s:%s\n' "$(image_ref)" "$(image_version)"
  printf 'mode    : %s\n' "$mode"
  printf 'fedora  : %s\n' "${AGENT_WORKSPACE_FEDORA:-unknown}"

  if getent passwd "$user" >/dev/null 2>&1; then
    printf 'agent   : %s (present)\n' "$user"
  else
    printf 'agent   : %s (created on first boot)\n' "$user"
  fi

  [[ -n "${agents// /}" ]] && printf 'harness : %s\n' "${agents% }"
  return 0
}
