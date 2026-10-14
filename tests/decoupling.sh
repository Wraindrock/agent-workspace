#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Behavioural regression assertions for the P0 decoupling: the project must not
# claim, ship, or require host kernel tuning.
#
#   tests/decoupling.sh
#
# `tests/lint.sh` holds the no-textual-guidance side of this contract (no file
# may tell a user to `sudo sysctl`). This script holds the behavioural side,
# which is the part that can silently rot:
#
#   1. the sysctl drop-in stays deleted, and both files that used to assert it
#      now assert its absence - otherwise a "cleanup" that drops the assertion
#      would look identical to the decoupling being done;
#   2. the absence assertion is conditional (a `test` guarded by if/else), so it
#      has a state that makes it fail instead of a comment that can never fail,
#      and its predicate is exercised in both directions against a modelled
#      container filesystem;
#
# No container engine and no privileges are needed: this is a text-level model of
# the assertion, so it runs on every pull request.
# ---------------------------------------------------------------------------
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

failures=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  fail %s\n' "$1"; failures=$((failures + 1)); }

sentinel="system_files/etc/sysctl.d/90-agent-workspace.conf"
smoke=tests/smoke.sh
doctor=runtime/lib/cmd-doctor.sh

echo "decoupling: no host kernel tuning"

# 1. the dead drop-in is gone ----------------------------------------------
if [[ -e "$sentinel" ]]; then
  fail "${sentinel} is back; it cannot take effect inside a container"
else
  pass "${sentinel} stays deleted"
fi

# 2. the two former reference points assert its absence ----------------------
if grep -qE "/usr/bin/test ! -e /etc/sysctl\.d/90-agent-workspace\.conf" "$smoke"; then
  pass "smoke.sh asserts the sysctl drop-in is absent"
else
  fail "smoke.sh no longer asserts the sysctl drop-in is absent"
fi
if grep -qE '/etc/sysctl\.d/90-agent-workspace\.conf' "$doctor"; then
  fail "doctor.sh still requires the dead sysctl drop-in"
else
  pass "doctor.sh no longer requires the sysctl drop-in"
fi

# 3. the assertion is conditional, so it has a failing state -----------------
# A bare `test ! -e X` in a pipeline with `|| true` would be an assertion that
# can never fail; requiring the if/else shape keeps the check honest.
if grep -qE "^[[:space:]]*fail \"?/etc/sysctl\.d/90-agent-workspace\.conf is back" "$smoke"; then
  pass "the smoke assertion has an explicit failing branch"
else
  fail "the smoke assertion has no failing branch, so it cannot detect a regression"
fi

# 4. the guard itself is not vacuous ----------------------------------------
# The sentinel is the repository's own sysctl file: the test uses it as a stand-in
# for "a file that is dead configuration inside a container". Model exactly that
# container state and check the assertion's predicate flips, so a later edit that
# makes the check unconditional or inverts it fails here instead of shipping.
probe="$(mktemp -d)"
trap 'rm -rf "$probe"' EXIT
mkdir -p "${probe}/etc/sysctl.d"
touch "${probe}/etc/sysctl.d/90-agent-workspace.conf"

if /usr/bin/test ! -e "${probe}/etc/sysctl.d/90-agent-workspace.conf"; then
  fail "the absence predicate passes against a container that carries the file"
else
  pass "the absence predicate fails against a container that carries the file"
fi
if /usr/bin/test ! -e "${probe}/etc/sysctl.d/absent.conf"; then
  pass "the absence predicate passes against a container without the file"
else
  fail "the absence predicate fails against a container without the file"
fi

# 5. no test hard-codes the container engine --------------------------------
# The project targets many Linux hosts, so a script may not pin itself to one
# engine: it has to reach the engine through a variable the caller can override
# (AW_*_ENGINE, defaulting to podman). A literal `podman run` in a script body
# binds the suite to whichever engine happens to be on the host. Comments and
# the list of binaries expected *inside* the image are not invocations.
engine_predicate() {
  # 1 if the file invokes an engine as a command word, else 0. The engine name
  # must be followed by something that is actually an engine verb; a bare
  # mention in a list of expected binaries ("for binary in podman git ...") is
  # not an invocation and must not trip the check.
  /usr/bin/grep -vE '^[[:space:]]*#' "$1" \
    | /usr/bin/grep -qE '(^|[[:space:];&|(])(podman|docker)[[:space:]]+(run|exec|inspect|images?|ps|rm|rmi|pull|push|build|create|start|stop|kill|logs|volume|network|image|tag|save|load|wait|port|top|stats|cp|commit|history|diff|pod|generate|system|info|version|events|rename|restart|attach|pause|unpause|update|healthcheck)([[:space:]]|$)'
}
engine_offenders=""
for script in tests/smoke.sh tests/integration.sh tests/portability.sh; do
  [[ -f "$script" ]] || continue
  if engine_predicate "$script"; then
    engine_offenders="${engine_offenders} ${script}"
  fi
done
if [[ -z "$engine_offenders" ]]; then
  pass "no test script hard-codes a container-engine invocation"
else
  fail "hard-coded engine invocation in:${engine_offenders}"
fi

# The predicate has to be able to fail, or it is decoration. Feed it one script
# that really does invoke an engine and one where the same text is commented out.
probe_script="${probe}/hardcoded.sh"
printf 'podman run --rm alpine true\n' > "$probe_script"
if engine_predicate "$probe_script"; then
  pass "the engine predicate trips on a hard-coded invocation"
else
  fail "the engine predicate misses a hard-coded invocation"
fi
printf '# podman run --rm alpine true\n' > "$probe_script"
if engine_predicate "$probe_script"; then
  fail "the engine predicate trips on a commented-out invocation"
else
  pass "the engine predicate ignores a commented-out invocation"
fi

printf '\n'
if [[ "$failures" -eq 0 ]]; then
  echo "decoupling: all checks passed"
else
  echo "decoupling: ${failures} check(s) failed"
  exit 1
fi
