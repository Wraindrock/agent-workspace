#!/usr/bin/env bash
# Verify that the running system matches the image declaration.
#
#   --quiet    only report problems
#   --offline  skip checks that need the network or a booted system
#   --strict   exit non-zero when any check fails

cmd_doctor() {
  local quiet=0 offline=0 strict=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --quiet) quiet=1 ;;
      --offline) offline=1 ;;
      --strict) strict=1 ;;
      *) die "unknown doctor flag: $1" ;;
    esac
    shift
  done

  local failures=0
  report_ok()   { [[ "$quiet" -eq 1 ]] || ok "$*"; }
  report_fail() { fail "$*"; failures=$((failures + 1)); }

  load_env

  printf 'agent-workspace doctor\n'
  [[ "$quiet" -eq 1 ]] || printf 'image: %s:%s\n' "$(image_ref)" "$(image_version)"

  # 1. declared toolchain ---------------------------------------------------
  local binary
  for binary in bootc podman git node npm python3 gh jq curl; do
    if have "$binary"; then
      report_ok "$binary present"
    else
      report_fail "$binary missing"
    fi
  done

  # 2. declarative files ----------------------------------------------------
  local asset
  for asset in "$MANIFEST_PATH" /etc/agent-workspace/build.env /etc/sysctl.d/90-agent-workspace.conf; do
    if [[ -r "$asset" ]]; then
      report_ok "$asset present"
    else
      report_fail "$asset missing"
    fi
  done

  # 3. declared agents ------------------------------------------------------
  local declared binary
  for declared in $(cmd_declared_agents); do
    # A recipe name is not always the command it installs (claude-code -> claude),
    # so check every binary the recipe declared in the manifest.
    for binary in $(agent_binaries_for "$declared"); do
      if have "$binary"; then
        report_ok "agent ${declared}: ${binary} available"
      else
        report_fail "agent ${declared} declared but ${binary} is not runnable"
      fi
    done
  done

  # 4. systemd units --------------------------------------------------------
  if [[ "$offline" -eq 0 ]] && ! is_container; then
    if systemctl is-enabled agent-workspace-firstboot.service >/dev/null 2>&1; then
      report_ok "firstboot service enabled"
    else
      report_fail "firstboot service not enabled"
    fi
    if systemctl is-active agent-workspace-health.timer >/dev/null 2>&1; then
      report_ok "health timer active"
    else
      report_fail "health timer inactive"
    fi
  fi

  # 5. bootc deployment -----------------------------------------------------
  if [[ "$offline" -eq 0 ]] && ! is_container; then
    if has_bootc; then
      if bootc status >/dev/null 2>&1; then
        report_ok "bootc reports a healthy deployment"
      else
        report_fail "bootc status failed"
      fi
    else
      report_fail "bootc unavailable on a booted system"
    fi
  fi

  printf 'doctor: %d failure(s)\n' "$failures"
  if [[ "$failures" -gt 0 && "$strict" -eq 1 ]]; then
    exit 1
  fi
  return 0
}

cmd_declared_agents() {
  [[ -r "$MANIFEST_PATH" ]] || return 0
  if have jq; then
    jq -r '.agents[]?' "$MANIFEST_PATH"
  fi
}
