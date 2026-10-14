#!/usr/bin/env bash
# Verify that the running system matches the image declaration.
#
#   --quiet    only report problems
#   --offline  skip checks that need systemd or the network
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
  for binary in podman git node npm python3 gh jq curl; do
    if have "$binary"; then
      report_ok "$binary present"
    else
      report_fail "$binary missing"
    fi
  done

  # 2. declarative files ----------------------------------------------------
  # The image declares no sysctl drop-in and does no host-level tuning. The
  # kernel settings it used to write there are wrong for this project in two
  # different ways, so declaring them was a false promise:
  #   - inotify instances/watches and vm.max_map_count are not namespaced. The
  #     kernel charges inotify per *uid*, shared with the host's desktop
  #     session, so the value a container reads is the host's, never the
  #     image's; `podman run --sysctl fs.inotify.max_user_instances=...` refuses
  #     the key outright ("is not allowed"), so the container cannot set it
  #     either.
  #   - the rest already hold where they matter: a rootless container gets a
  #     private network namespace with its own somaxconn (4096 on a current
  #     kernel) and ip_unprivileged_port_start (1024 there is not a limit, since
  #     every published port is remapped by the engine anyway).
  # /etc/sysctl.d belongs to the host, and `install.sh` never touches it.
  # Only what the image really owns is asserted here.
  local asset
  for asset in "$MANIFEST_PATH" /etc/agent-workspace/build.env; do
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
