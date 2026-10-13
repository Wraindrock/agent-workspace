#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Revert a booted agent-workspace host to its previously booted deployment.
#
# bootc deployments are transactional: the update is staged as a new
# deployment and only becomes active after a reboot, so rollback never has to
# re-download or rebuild anything. Running it twice rolls forward again.
#
#   scripts/rollback.sh
#   scripts/rollback.sh --status
# ---------------------------------------------------------------------------
set -euo pipefail

if [[ "${1:-}" == "--status" || "${1:-}" == "-s" ]]; then
  if command -v agent-workspace >/dev/null 2>&1; then
    exec agent-workspace status
  fi
  exec bootc status
fi

if command -v agent-workspace >/dev/null 2>&1; then
  exec agent-workspace rollback
fi

echo "rolling back to the previous deployment"
exec bootc rollback
