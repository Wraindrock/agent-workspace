#!/usr/bin/env bash
# Booted / staged / previous deployment status.

cmd_status() {
  load_env
  printf 'image   : %s:%s\n' "$(image_ref)" "$(image_version)"

  local pinned
  pinned="$(pinned_digest)"
  [[ -n "$pinned" ]] && printf 'pinned  : %s\n' "$pinned"

  if is_container; then
    printf 'mode    : container (not a booted system container)\n'
    printf 'note    : bootc rollback/switch are only available when booted\n'
    return 0
  fi

  if ! has_bootc; then
    printf 'mode    : unknown (bootc not available)\n'
    return 0
  fi

  if [[ "${1:-}" == "--json" ]] && have jq; then
    bootc status --json
    return 0
  fi

  bootc status || die "bootc status failed"
}
