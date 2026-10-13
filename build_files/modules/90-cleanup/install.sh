#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../lib/common.sh
source "${COMMON_LIB:?COMMON_LIB must point at build_files/lib/common.sh}"

dnf5 clean all || true
rm -rf /var/cache/dnf /var/cache/libdnf5 /var/cache/PackageKit
find /var/log -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
rm -rf /tmp/* /tmp/.[!.]* 2>/dev/null || true
rm -rf /var/tmp/* 2>/dev/null || true

# Remove the build state so it cannot be mistaken for runtime state.
rm -rf "${STATE_DIR}"

# Directories that must exist at runtime even on a fresh /var.
install -d -m 0755 /var/lib/agent-workspace/cache /var/lib/agent-workspace/sessions
install -d -m 0755 /etc/agent-workspace

ok "cleanup complete"
