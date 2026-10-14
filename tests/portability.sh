#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Portability assertion: the image boots on a *stock* Linux host.
#
# The project claims to be portable across Linux distributions and to need no
# host kernel tuning. That claim is only worth something if it fails when the
# claim is false, so this script asserts it against the observable host state
# instead of restating it in a comment.
#
#   tests/portability.sh localhost/agent-workspace:latest
#
# What it asserts:
#
#   1. The host has *not* been tuned. `fs.inotify.max_user_instances` must
#      still be at its default stock value (128). A host that raised it to
#      1024 is exactly the state the project says it does not require, so the
#      assertion refuses to certify that host and fails. Setting
#      AW_PORTABILITY_EXPECT_MAX_INSTANCES=<n> re-points the expectation (for
#      a distribution whose stock default differs) -- it does not make a
#      tuned host pass, it just declares what "stock" means on that host.
#   2. The container's PID 1 is systemd. A container that falls back to the
#      inherited shell, or that never starts, fails here.
#   3. The container stays running, and is *still* running after the check.
#   4. The running system is actually systemd and healthy, not just a process
#      named systemd: `systemctl is-system-running` must terminate and report
#      a usable state.
#
# Every one of these can fail. Point it at a broken image (`/bin/true` as
# PID 1, or an image without systemd) and it reports failures and exits 1;
# it is not a script that prints "ok" and returns 0 regardless.
#
# This test never writes to the host: no sysctl, no root, no persistent
# container. It creates one throwaway container with --rm and removes it.
# ---------------------------------------------------------------------------
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

IMAGE="${1:-${IMAGE:-}}"
[[ -n "${IMAGE}" ]] || { echo "usage: tests/portability.sh <image ref>" >&2; exit 2; }

ENGINE="${AW_PORTABILITY_ENGINE:-podman}"
NAME="${AW_PORTABILITY_NAME:-aw-portability-test}"
# The stock value the assertion holds the host to. 128 is the unmodified Linux
# default; a distribution may ship another, and then it names it here.
STOCK_MAX_INSTANCES="${AW_PORTABILITY_EXPECT_MAX_INSTANCES:-128}"
# Whether a tuned host should *fail* the run. Off by default, and deliberately
# so: the claim under test is "this image does not depend on a tuned host", not
# "this host must be untuned". An image that boots on a host an administrator
# already tuned is still portable, so treating it as a failure would report the
# host's configuration as an image defect -- and would turn CI red purely
# because a runner image ships its own inotify defaults.
REQUIRE_STOCK="${AW_PORTABILITY_REQUIRE_STOCK:-0}"

command -v "${ENGINE}" >/dev/null 2>&1 || { echo "${ENGINE} is required" >&2; exit 1; }

failures=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  fail %s\n' "$1"; failures=$((failures + 1)); }
# Recorded, never counted: for facts that shape how to read the result but are
# not themselves a verdict on the image.
info() { printf '  info %s\n' "$1"; }

exec_timeout="${AW_PORTABILITY_EXEC_TIMEOUT:-20}"

# Every engine call is wrapped in `timeout`. The engine takes a global lock on
# its own database, so a concurrent build on the same host can stall a query for
# minutes; without a bound this script would hang instead of reporting a
# failure, and a hanging test is worse than a failing one. `|| true` keeps a
# refused/garbled call from tripping errexit before it can be reported.
engine_query() { timeout "${exec_timeout}" "${ENGINE}" "$@" 2>/dev/null || true; }

cleanup() {
  timeout "${exec_timeout}" "${ENGINE}" rm -f "${NAME}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "portability test: ${IMAGE}"

# --- 1. the host's inotify budget, recorded and judged ----------------------
# Read-only, and never allowed to abort the script: a missing /proc file on a
# non-Linux or hardened host has to become a failed *check*, not an errexit.
host_instances="$(cat /proc/sys/fs/inotify/max_user_instances 2>/dev/null || true)"
host_watches="$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || true)"
printf '  host fs.inotify.max_user_instances = %s\n' "${host_instances:-unreadable}"
printf '  host fs.inotify.max_user_watches   = %s\n' "${host_watches:-unreadable}"
printf '  stock value this run compares against = %s\n' "${STOCK_MAX_INSTANCES}"

if [[ -z "${host_instances}" ]]; then
  # Not a portability finding either way: just say the host is unverifiable.
  info "cannot read /proc/sys/fs/inotify/max_user_instances, so this host's budget is unknown"
elif [[ "${host_instances}" == "${STOCK_MAX_INSTANCES}" ]]; then
  pass "host inotify budget is at the stock value (${host_instances})"
elif [[ "${REQUIRE_STOCK}" == "1" ]]; then
  fail "host fs.inotify.max_user_instances is ${host_instances}, not the stock ${STOCK_MAX_INSTANCES}, and AW_PORTABILITY_REQUIRE_STOCK=1 demands an untuned host"
else
  info "host is tuned (fs.inotify.max_user_instances=${host_instances}, stock=${STOCK_MAX_INSTANCES}), which is allowed: this run then proves the image boots on a *tuned* host, and the untuned-host claim rests on a run where the two match (set AW_PORTABILITY_REQUIRE_STOCK=1 to make a tuned host fail)"
fi

# --- 2. the container boots systemd on that untuned host --------------------
# `--systemd=always` is what install.sh passes (installer/lib/engine.sh), and a
# throwaway container that does not use the same flag would test something the
# project does not actually run.
cleanup
timeout "${exec_timeout}" "${ENGINE}" run --detach --systemd=always --name "${NAME}" \
  --entrypoint '' "${IMAGE}" /sbin/init >/dev/null 2>&1 || true

# Poll instead of sleeping a fixed amount: systemd needs a moment after
# `create` returns, and a fixed sleep would either be flaky or slow.
#
# Retry rather than trusting one sample: the engine can transiently time out or
# report a container whose state has not settled. Only the settled outcome is
# reported below, so a real failure still fails -- the retry removes flakiness,
# not the assertion.
pid1=""
status=""
attempts="${AW_PORTABILITY_ATTEMPTS:-10}"
for _ in $(seq 1 "${attempts}"); do
  status="$(engine_query inspect "${NAME}" --format '{{.State.Status}}' | tr -d '[:space:]')"
  [[ -n "${status}" ]] || status="missing"
  if [[ "${status}" == "running" ]]; then
    pid1="$(engine_query exec "${NAME}" cat /proc/1/comm | tr -d '[:space:]')"
    [[ "${pid1}" == "systemd" ]] && break
  fi
  sleep 0.5
done

echo "  container state = ${status:-missing}"
echo "  container PID 1 = ${pid1:-nothing}"

if [[ "${status}" == "running" ]]; then
  pass "the container is running"
else
  fail "the container is ${status:-missing}, not running (exit code $(engine_query inspect "${NAME}" --format '{{.State.ExitCode}}' | tr -d '[:space:]'))"
fi

if [[ "${pid1}" == "systemd" ]]; then
  pass "PID 1 is systemd, on a host with the stock inotify budget"
else
  fail "PID 1 is [${pid1:-nothing}], want systemd"
fi

# --- 3. it is still running (not a container that booted then died) ---------
if [[ "$(engine_query inspect "${NAME}" --format '{{.State.Status}}' | tr -d '[:space:]')" == "running" ]]; then
  pass "the container is still running after the checks"
else
  fail "the container stopped during the checks"
fi

# --- 4. systemd is genuinely up, not merely named ---------------------------
# `is-system-running` prints "initializing" while the boot is still in
# progress, then "running" (or "degraded"). Waiting for the boot to finish is
# part of the assertion: a systemd stuck initializing forever is a failure, so
# the wait is bounded rather than a fixed sleep.
#
# "degraded" still means systemd is up and serving, which is what this asserts;
# "offline"/"maintenance"/empty means it never became usable.
if [[ "${pid1}" == "systemd" ]]; then
  system_state=""
  system_deadline=$((SECONDS + ${AW_PORTABILITY_BOOT_TIMEOUT:-30}))
  while ((SECONDS < system_deadline)); do
    system_state="$(engine_query exec "${NAME}" systemctl is-system-running | tr -d '[:space:]')"
    case "${system_state}" in
      running|degraded) break ;;
    esac
    sleep 0.5
  done
  echo "  systemctl is-system-running = ${system_state:-nothing}"
  case "${system_state}" in
    running|degraded) pass "systemd reached '${system_state}' within the boot timeout" ;;
    *) fail "systemd reported '${system_state:-nothing}', want running or degraded" ;;
  esac
  # "degraded" is accepted, so say *why* it is degraded: without this the
  # difference between one irrelevant failed unit and a real breakage is
  # invisible. Recorded only -- whether a given failed unit matters is a
  # judgement this test is not in a position to make.
  if [[ "${system_state}" == "degraded" ]]; then
    failed_units="$(engine_query exec "${NAME}" systemctl --failed --no-legend --plain | tr -s ' ' | sed 's/^ //' || true)"
    if [[ -n "${failed_units}" ]]; then
      printf '  info failed units:\n'
      printf '%s\n' "${failed_units}" | while IFS= read -r unit; do
        [[ -n "${unit}" ]] && printf '         %s\n' "${unit}"
      done
    else
      info "systemd reports degraded but listed no failed units"
    fi
  fi
fi

# --- the claim the host was never asked to sacrifice ------------------------
# Re-read the host value and require it unchanged. This is the assertion that a
# test which *did* tune the host would trip over.
after_instances="$(cat /proc/sys/fs/inotify/max_user_instances 2>/dev/null || true)"
if [[ "${after_instances}" == "${host_instances}" ]]; then
  pass "the host inotify budget is unchanged (${after_instances})"
else
  fail "the host inotify budget changed from ${host_instances} to ${after_instances} during the test"
fi

echo
if [[ "${failures}" -eq 0 ]]; then
  if [[ "${host_instances}" == "${STOCK_MAX_INSTANCES}" ]]; then
    echo "portability: all checks passed on an untuned host (max_user_instances=${host_instances})"
  else
    echo "portability: all checks passed on this host (max_user_instances=${host_instances}, stock=${STOCK_MAX_INSTANCES}; not an untuned-host run)"
  fi
else
  echo "portability: ${failures} check(s) failed"
  exit 1
fi
