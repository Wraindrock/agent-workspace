#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../lib/common.sh
source "${COMMON_LIB:?COMMON_LIB must point at build_files/lib/common.sh}"

dnf5 clean all || true
rm -rf /var/cache/dnf /var/cache/libdnf5 /var/cache/PackageKit /var/cache/agent-workspace
find /var/log -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
rm -rf /tmp/* /tmp/.[!.]* 2>/dev/null || true
rm -rf /var/tmp/* 2>/dev/null || true
# dnf5 keeps transaction state in /run/dnf, and /run must be empty in the image:
# `bootc container lint` flags it as nonempty-run-tmp otherwise.
rm -rf /run/dnf
# Installing cloud-init writes a runtime stamp under /run/cloud-init, and
# /run must be empty in the image: bootc container lint flags it as
# nonempty-run-tmp (the KVM backend seeds cloud-init at boot instead).
rm -rf /run/cloud-init
# pipx logs every command and keeps a cache beside it. Both are build artifacts
# of the image-wide pipx home (/opt/pipx -> /var/opt/pipx) and must not ship.
rm -rf /var/opt/pipx/logs /var/opt/pipx/.cache

# The build state under ${STATE_DIR} is removed by build_files/build.sh after
# it prints the build summary, so the summary can still report what was applied.

# Directories that must exist at runtime even on a fresh /var.
install -d -m 0755 /var/lib/agent-workspace/cache /var/lib/agent-workspace/sessions
install -d -m 0755 /etc/agent-workspace

ok "cleanup complete"
