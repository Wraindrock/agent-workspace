#!/usr/bin/env bash
# switch / rollback / update / pin - the declarative, reversible lifecycle.

cmd_switch() {
  require_root
  has_bootc || die "bootc is not available; this is not a booted system container"

  local tag="${1:-latest}"
  local image target
  image="$(image_ref)"
  target="${image}:${tag}"

  local pinned
  pinned="$(pinned_digest)"
  if [[ -n "$pinned" && "${2:-}" != "--ignore-pin" ]]; then
    die "this host is pinned to $pinned; run 'agent-workspace pin --clear' first"
  fi

  log "switching to ${target}"
  bootc switch --transport registry "$target"

  mkdir -p "$STATE_ROOT"
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$target" >> "$STATE_ROOT/switch.log"
  ok "reboot to complete the switch; 'agent-workspace rollback' reverts it"
}

cmd_rollback() {
  require_root
  has_bootc || die "bootc is not available; this is not a booted system container"

  log "rolling back to the previously booted deployment"
  bootc rollback
  mkdir -p "$STATE_ROOT"
  printf '%s rollback\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$STATE_ROOT/switch.log"
  ok "reboot to boot the previous deployment; running it again re-rolls forward"
}

cmd_update() {
  require_root
  has_bootc || die "bootc is not available; this is not a booted system container"

  local pinned
  pinned="$(pinned_digest)"
  if [[ -n "$pinned" ]]; then
    log "host is pinned, updating to $pinned"
    bootc update --quiet || bootc switch --transport registry "$pinned"
  else
    log "checking for updates on $(image_ref)"
    bootc update
  fi
  ok "update staged; reboot to apply"
}

cmd_pin() {
  require_root
  local file="${PinnedDigestFile:-/etc/agent-workspace/pinned-digest}"

  if [[ "${1:-}" == "--clear" ]]; then
    rm -f "$file"
    ok "pin removed"
    return 0
  fi

  has_bootc || die "bootc is not available; cannot determine the booted image digest"
  have jq || die "jq is required to read 'bootc status --json'"

  local digest
  digest="$(bootc status --json | jq -r '.status.booted.image.imageDigest // .booted.image.imageDigest // empty')"
  [[ -n "$digest" ]] || die "could not determine the booted image digest"

  install -d -m 0755 "$(dirname "$file")"
  printf '%s\n' "$digest" > "$file"
  ok "pinned to $digest (rollback-proof and upgrade-proof)"
}
