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
# It needs a host where rootless podman can start systemd. That is the default
# on a stock Linux desktop: the image does not need, and this project does not
# ask for, any host kernel tuning. The inotify instance budget is a *shared*
# per-uid host resource, so if the host desktop session has already spent it,
# systemd cannot start in any container. The failure diagnosis below reports
# that budget instead of asking anyone to raise it (the budget is not
# namespaced, so no container can work around it, and `--sysctl` refuses the
# key outright).
# ---------------------------------------------------------------------------
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

IMAGE="${1:-${IMAGE:-}}"
[[ -n "${IMAGE}" ]] || { echo "usage: tests/integration.sh <image ref>" >&2; exit 2; }

NAME="${AW_INTEGRATION_NAME:-aw-integration-test}"
AGENT="${AW_INTEGRATION_AGENT:-dsh}"
ENGINE="${AW_INTEGRATION_ENGINE:-podman}"
VOLUME="agent-workspace-${NAME}-home"
WORKSPACE="${HOME}/agent-workspace/${NAME}"
# The installer records a container under $DATA_HOME, not just in the engine:
# `install.sh create` skips a name that already has state, and reports success
# while creating nothing. Leaving that state behind would fail the *next* run,
# so cleanup owns it too.
DATA_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/agent-workspace/containers/${NAME}"
CONF_ENV="${XDG_CONFIG_HOME:-${HOME}/.config}/agent-workspace/containers/${NAME}.env"

command -v "${ENGINE}" >/dev/null 2>&1 || { echo "${ENGINE} is required" >&2; exit 1; }

failures=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  fail %s\n' "$1"; failures=$((failures + 1)); }

# Count inotify instances currently held by the processes this user can see.
# /proc only exposes our own processes, so on a shared uid this is a lower
# bound - which is the honest thing to print next to the host's ceiling. Used
# only on the failure path, and never allowed to fail the script itself.
host_inotify_instances() {
  local fd target count=0
  for fd in /proc/[0-9]*/fd/*; do
    target="$(readlink "$fd" 2>/dev/null || true)"
    case "$target" in
      anon_inode:inotify*) count=$((count + 1));;
    esac
  done
  printf '%s' "$count"
}

cleanup() {
  "${ENGINE}" rm -f "${NAME}" >/dev/null 2>&1 || true
  "${ENGINE}" volume rm "${VOLUME}" >/dev/null 2>&1 || true
  rm -f "${CONF_ENV}" 2>/dev/null || true
  rm -rf "${DATA_DIR}" 2>/dev/null || true
  rmdir "${WORKSPACE}" >/dev/null 2>&1 || true
  rmdir "$(dirname "${WORKSPACE}")" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Start from a clean slate so a leftover container cannot fake a pass, and say
# so out loud: if the installer still sees state for this name, everything below
# would silently test nothing.
cleanup
if [[ -e "${DATA_DIR}" ]]; then
  fail "state for ${NAME} survived cleanup (${DATA_DIR}); the run below cannot prove anything"
  echo "integration: ${failures} check(s) failed"
  exit 1
fi
echo "integration test: ${IMAGE}"

# The real entry point, non-interactively, with the real engine. stdin is closed
# so the credential prompt falls back to "no terminal for prompts".
if bash install.sh create --agent "${AGENT}" --name "${NAME}" --image "${IMAGE}" \
     --engine "${ENGINE}" --no-web --yes </dev/null; then
  pass "install.sh create"
else
  fail "install.sh create"
fi

status="$("${ENGINE}" inspect "${NAME}" --format '{{.State.Status}}' 2>/dev/null || echo missing)"
if [[ "${status}" == "running" ]]; then
  pass "the created container is running"
  pid1="$("${ENGINE}" exec "${NAME}" cat /proc/1/comm 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ "${pid1}" == "systemd" ]]; then
    pass "PID 1 is systemd"
  else
    fail "PID 1 is [${pid1:-nothing}], want systemd"
  fi
  if "${ENGINE}" exec "${NAME}" test -d /home/agent; then
    pass "/home/agent exists (the agent home volume is mounted)"
  else
    fail "/home/agent is missing inside the container"
  fi
  if "${ENGINE}" exec "${NAME}" findmnt -n -o TARGET /home/agent >/dev/null 2>&1; then
    pass "/home/agent is a mount point"
  else
    fail "/home/agent is not a mount point"
  fi

  # The image's default dsh plugin set is seeded into the agent's home by the
  # first boot, which runs asynchronously -- with --no-web nothing on the
  # installer side waits for it -- so give it a bounded window and then judge
  # the result. An image built without the module says so instead of failing.
  if "${ENGINE}" exec "${NAME}" test -d /usr/share/agent-workspace/dsh/profiles; then
    for _ in $(seq 1 60); do
      if "${ENGINE}" exec "${NAME}" test -f /var/lib/agent-workspace/.provisioned; then
        break
      fi
      sleep 1
    done
    if "${ENGINE}" exec "${NAME}" test -f /var/lib/agent-workspace/.provisioned; then
      pass "the first boot finished (completion marker written)"
    else
      fail "the first boot did not finish within 60s"
    fi
    seeded="/home/agent/.dsh/profiles/web"
    if "${ENGINE}" exec "${NAME}" test -f "${seeded}/package.json"; then
      pass "the default dsh plugin set is seeded into the agent's home"
    else
      fail "${seeded}/package.json is missing"
    fi
    shipped_version="$("${ENGINE}" exec "${NAME}" cat /usr/share/agent-workspace/dsh/profiles.version 2>/dev/null | tr -d '[:space:]' || true)"
    seeded_version="$("${ENGINE}" exec "${NAME}" sed -n 's/^version //p' "${seeded}/.agent-workspace-profile" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ -n "${shipped_version}" ]] && [[ "${seeded_version}" == "${shipped_version}" ]]; then
      pass "the seeded profile records the image's plugin set (${shipped_version})"
    else
      fail "the seeded profile records [${seeded_version:-nothing}], the image ships [${shipped_version:-nothing}]"
    fi
    seeded_digest="$("${ENGINE}" exec "${NAME}" sha256sum "${seeded}/package.json" 2>/dev/null | cut -d' ' -f1 || true)"
    shipped_digest="$("${ENGINE}" exec "${NAME}" sha256sum /usr/share/agent-workspace/dsh/profiles/web/package.json 2>/dev/null | cut -d' ' -f1 || true)"
    if [[ -n "${seeded_digest}" ]] && [[ "${seeded_digest}" == "${shipped_digest}" ]]; then
      pass "the seeded profile is the image's, byte for byte"
    else
      fail "the seeded package.json is not the image's"
    fi
    if "${ENGINE}" exec "${NAME}" test -f "${seeded}/node_modules/.modules.yaml"; then
      pass "the seeded profile carries the dependencies the build installed"
    else
      fail "${seeded} has no installed node_modules"
    fi
  else
    echo "  --   this image ships no dsh plugin set (45-dsh-plugins off)"
  fi
else
  fail "the created container is ${status}, not running"
fi

if [[ "${failures}" -gt 0 ]]; then
  echo
  echo "recent log lines from ${NAME}:"
  "${ENGINE}" logs --tail 25 "${NAME}" 2>&1 | sed 's/^/  /' || true
  if "${ENGINE}" logs "${NAME}" 2>&1 | grep -qE 'Too many open files|Too many open files in system'; then
    echo
    echo "The container reported 'Too many open files' while starting systemd."
    echo
    echo "This is a host budget, not an image defect. The kernel charges inotify"
    echo "instances per *uid*, not per container, and the value is not namespaced:"
    echo "every container that boots systemd spends from the same budget as your"
    echo "desktop session. Raising it would need root on the host, and the project"
    echo "does not ask for that -- no image can work around it, because the engine"
    echo "refuses to set the key ('sysctl fs.inotify.max_user_instances is not"
    echo "allowed')."
    echo
    echo "The host budget right now:"
    echo "  fs.inotify.max_user_instances = $(cat /proc/sys/fs/inotify/max_user_instances 2>/dev/null || echo unknown)"
    echo "  inotify instances visible to this shell = $(host_inotify_instances) (a lower bound:"
    echo "    /proc only exposes your own processes)"
    echo
    echo "Before treating this as exhaustion, confirm it:"
    echo "  1. A container that boots systemd fails the same way at the same point"
    echo "     (the log above ends at 'Failed to allocate manager object'), while a"
    echo "     trivial container still starts:"
    echo "       ${ENGINE} run --rm ${IMAGE} /bin/true"
    echo "  2. The budget above is exhausted or nearly so. If it has room to spare,"
    echo "     the cause is something else -- check the rest of the log for the"
    echo "     first error, not the last one."
  fi
  echo
  echo "integration: ${failures} check(s) failed"
  exit 1
fi

echo
echo "integration: all checks passed"
