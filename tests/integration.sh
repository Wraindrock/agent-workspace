#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# End-to-end test: the container `install.sh` creates has to actually boot.
#
# tests/install.sh drives a fake engine (no container is ever created) and
# tests/smoke.sh overrides the image command with `--entrypoint`, so neither can
# catch an image whose PID 1 never starts or whose /home does not resolve. This
# test uses the real engine and the real installer, which is the only thing that
# proves the documented first step works.
#
#   tests/integration.sh localhost/agent-workspace:latest
#
# It needs a host where rootless podman can start systemd. On a machine whose
# inotify instance budget is exhausted systemd cannot start in any container
# (fs.inotify.max_user_instances, charged per uid); the test prints that
# diagnosis instead of blaming the image.
# ---------------------------------------------------------------------------
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

IMAGE="${1:-${IMAGE:-}}"
[[ -n "${IMAGE}" ]] || { echo "usage: tests/integration.sh <image ref>" >&2; exit 2; }

command -v podman >/dev/null 2>&1 || { echo "podman is required" >&2; exit 1; }

NAME="${AW_INTEGRATION_NAME:-aw-integration-test}"
AGENT="${AW_INTEGRATION_AGENT:-dsh}"
ENGINE="${AW_INTEGRATION_ENGINE:-podman}"
VOLUME="agent-workspace-${NAME}-home"
WORKSPACE="${HOME}/agent-workspace/${NAME}"

failures=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  fail %s\n' "$1"; failures=$((failures + 1)); }

cleanup() {
  podman rm -f "${NAME}" >/dev/null 2>&1 || true
  podman volume rm "${VOLUME}" >/dev/null 2>&1 || true
  rm -f "${HOME}/.config/agent-workspace/containers/${NAME}.env" 2>/dev/null || true
  rmdir "${WORKSPACE}" >/dev/null 2>&1 || true
  rmdir "$(dirname "${WORKSPACE}")" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Start from a clean slate so a leftover container cannot fake a pass.
cleanup
echo "integration test: ${IMAGE}"

# The real entry point, non-interactively, with the real engine. stdin is closed
# so the credential prompt falls back to "no terminal for prompts".
if bash install.sh create --agent "${AGENT}" --name "${NAME}" --image "${IMAGE}" \
     --engine "${ENGINE}" --no-web --yes </dev/null; then
  pass "install.sh create"
else
  fail "install.sh create"
fi

status="$(podman inspect "${NAME}" --format '{{.State.Status}}' 2>/dev/null || echo missing)"
if [[ "${status}" == "running" ]]; then
  pass "the created container is running"
  pid1="$(podman exec "${NAME}" cat /proc/1/comm 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ "${pid1}" == "systemd" ]]; then
    pass "PID 1 is systemd"
  else
    fail "PID 1 is [${pid1:-nothing}], want systemd"
  fi
  if podman exec "${NAME}" test -d /home/agent; then
    pass "/home/agent exists (the agent home volume is mounted)"
  else
    fail "/home/agent is missing inside the container"
  fi
  if podman exec "${NAME}" findmnt -n -o TARGET /home/agent >/dev/null 2>&1; then
    pass "/home/agent is a mount point"
  else
    fail "/home/agent is not a mount point"
  fi
else
  fail "the created container is ${status}, not running"
fi

if [[ "${failures}" -gt 0 ]]; then
  echo
  echo "recent log lines from ${NAME}:"
  podman logs --tail 25 "${NAME}" 2>&1 | sed 's/^/  /' || true
  if podman logs "${NAME}" 2>&1 | grep -q 'Too many open files'; then
    echo
    echo "This host ran out of inotify instances, so systemd cannot start in any"
    echo "container. That is a host limit, not an image defect:"
    echo "  sysctl fs.inotify.max_user_instances   # now: $(sysctl -n fs.inotify.max_user_instances 2>/dev/null || echo unknown)"
    echo "  sudo sysctl -w fs.inotify.max_user_instances=1024"
    echo "  echo 'fs.inotify.max_user_instances=1024' | sudo tee /etc/sysctl.d/99-inotify.conf"
  fi
  echo
  echo "integration: ${failures} check(s) failed"
  exit 1
fi

echo
echo "integration: all checks passed"
