#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Container self test: boots the built image as a plain container and checks
# the promises the image makes, without needing a booted system.
#
#   tests/smoke.sh ghcr.io/wraindrock/agent-workspace:latest
#   tests/smoke.sh localhost/agent-workspace:dev
# ---------------------------------------------------------------------------
set -euo pipefail

IMAGE="${1:-}"
[[ -n "$IMAGE" ]] || { echo "usage: tests/smoke.sh <image ref>" >&2; exit 2; }

command -v podman >/dev/null 2>&1 || { echo "podman is required" >&2; exit 1; }

failures=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  fail %s\n' "$1"; failures=$((failures + 1)); }

in_image() {
  podman run --rm --entrypoint "$1" "$IMAGE" "${@:2}"
}

echo "smoke test: ${IMAGE}"

if in_image /usr/bin/agent-workspace version >/dev/null; then
  pass "agent-workspace version"
else
  fail "agent-workspace version"
fi

if in_image /usr/bin/agent-workspace manifest --json | jq -e '.modules | length > 0' >/dev/null 2>&1; then
  pass "manifest declares at least one module"
else
  fail "manifest is missing or empty"
fi

if in_image /usr/bin/agent-workspace doctor --offline --strict --quiet >/dev/null 2>&1; then
  pass "doctor --offline --strict"
else
  fail "doctor --offline --strict"
fi

for binary in podman git node npm python3 gh jq curl tmux nvim rg; do
  if in_image /bin/bash -c "command -v ${binary} >/dev/null"; then
    pass "binary ${binary}"
  else
    fail "binary ${binary}"
  fi
done

# The image publishes the agents it ships; every binary in that catalog has to
# be runnable, otherwise install.sh would offer an agent the image cannot start.
catalog="$(in_image /usr/bin/agent-workspace manifest --json 2>/dev/null | jq -r '(.agentCatalog // {}) | to_entries[] | .value.binaries[]' 2>/dev/null || true)"
if [[ -z "$catalog" ]]; then
  fail "manifest declares no agent catalog"
else
  for binary in $catalog; do
    if in_image /bin/bash -c "command -v ${binary} >/dev/null"; then
      pass "agent binary ${binary}"
    else
      fail "agent binary ${binary}"
    fi
  done
fi

for unit in /etc/systemd/system/agent-workspace-firstboot.service \
            /usr/lib/systemd/system/agent-workspace-health.timer \
            /etc/sysctl.d/90-agent-workspace.conf; do
  if in_image /usr/bin/test -r "$unit"; then
    pass "${unit}"
  else
    fail "${unit}"
  fi
done

echo
if [[ "$failures" -eq 0 ]]; then
  echo "smoke: all checks passed"
else
  echo "smoke: ${failures} check(s) failed"
  exit 1
fi
