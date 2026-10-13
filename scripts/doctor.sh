#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Verify a host (or a running container) against the image's own declaration.
#
#   scripts/doctor.sh                 full check, reports only
#   scripts/doctor.sh --strict        exit non-zero on failure (used by CI)
#   scripts/doctor.sh --offline       skip network and bootc checks
# ---------------------------------------------------------------------------
set -euo pipefail

if command -v agent-workspace >/dev/null 2>&1; then
  exec agent-workspace doctor "$@"
fi

# Fallback for hosts that do not have the image CLI (for example a plain
# container or a rescue environment).
echo "agent-workspace CLI not found, running a reduced check"

failures=0
check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  ok   ${label}"
  else
    echo "  fail ${label}"
    failures=$((failures + 1))
  fi
}

check "manifest present" test -r /usr/share/agent-workspace/manifest.json
check "bootc present" command -v bootc
check "podman present" command -v podman
check "git present" command -v git
check "node present" command -v node
check "python3 present" command -v python3

echo "doctor: ${failures} failure(s)"

if [[ "${1:-}" == "--strict" && "$failures" -gt 0 ]]; then
  exit 1
fi
exit 0
