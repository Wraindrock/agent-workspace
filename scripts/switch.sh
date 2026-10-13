#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Move a booted agent-workspace host to another published tag.
#
#   scripts/switch.sh --status          show the current deployment
#   scripts/switch.sh latest            follow the moving tag
#   scripts/switch.sh 20261013          pin to a dated build
#   scripts/switch.sh previous          jump to the last published build
#
# Runs on the host (use sudo); delegates to the in-image CLI when present so
# that there is exactly one implementation of the lifecycle logic.
# ---------------------------------------------------------------------------
set -euo pipefail

IMAGE="${AGENT_WORKSPACE_IMAGE:-ghcr.io/wraindrock/agent-workspace}"
DRY_RUN=0
STATUS=0
TAG="latest"

for arg in "$@"; do
  case "$arg" in
    --status|-s) STATUS=1 ;;
    --dry-run|-n) DRY_RUN=1 ;;
    -*) echo "unknown flag: $arg" >&2; exit 2 ;;
    *) TAG="$arg" ;;
  esac
done

if [[ "$STATUS" -eq 1 ]]; then
  if command -v agent-workspace >/dev/null 2>&1; then
    exec agent-workspace status
  fi
  exec bootc status
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "would run: bootc switch --transport registry ${IMAGE}:${TAG}"
  exit 0
fi

if command -v agent-workspace >/dev/null 2>&1; then
  exec agent-workspace switch "$TAG"
fi

echo "switching to ${IMAGE}:${TAG}"
exec bootc switch --transport registry "${IMAGE}:${TAG}"
