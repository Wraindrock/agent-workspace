#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../lib/common.sh
source "${COMMON_LIB:?COMMON_LIB must point at build_files/lib/common.sh}"

# Units shipped through the system_files/ overlay.
enable_unit agent-workspace-firstboot.service
enable_unit agent-workspace-health.timer

# Presets let a host admin re-disable things after the fact. `--root=/` keeps
# this working in an image build, where PID 1 is not systemd.
if [[ -d /etc/systemd/system-preset ]]; then
  systemctl --root=/ preset-all --preset-mode=enable-only >/dev/null 2>&1 ||
    warn "systemctl preset-all failed (presets will be applied on first boot)"
fi

# The agent user's shell niceties live in /etc/skel so first-boot user creation
# inherits them.
install -d -m 0755 /etc/skel/.config
install -d -m 0755 /etc/skel/.local/bin
install -d -m 0755 /etc/skel/agent-workspace

# Everything under /var/lib/agent-workspace is state, not image content.
install -d -m 0755 /var/lib/agent-workspace/cache
install -d -m 0755 /var/lib/agent-workspace/sessions
