#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Behavioural regression assertions for firstboot provisioning.
#
#   tests/firstboot.sh
#
# firstboot runs once per container, as PID 1's systemd, with no terminal and
# nothing to fall back on. Two properties are easy to break and catastrophic
# when broken, because neither shows up until a user's container misbehaves:
#
#   1. the completion marker must be written even when setting ownership of the
#      agent's directories is impossible. A rootless container runs in a user
#      namespace that frequently maps a single id (`0 1000 1`), so `chown agent`
#      is EINVAL -- for every possible value, because the namespace cannot name
#      the target uid at all. Under `set -e` that used to abort the unit, skip
#      the marker, and leave the container provisioning itself again on every
#      single boot.
#
#   2. "cannot name this uid" must be told apart from "this failed". Only the
#      first is acceptable to continue past; the second is a real provisioning
#      failure. Collapsing them with a blanket `|| true` hides disk-full and
#      read-only-mount failures.
#
# The `id_is_mapped` predicate decides which branch is taken, so it is the part
# that silently rots. It reads /proc/self/uid_map, whose columns are
# "inside_id outside_id length" -- reading the *second* column as the length
# widens every range to the outside id (e.g. `1001 1001 64535` becomes
# 1001..2001 instead of 1001..66535) and makes unmappable uids look addressable.
# That slip turned a "skipped" into a "failed" and is asserted against three
# real mapping shapes below.
#
# No container engine, no root and no image are needed: the predicate is
# extracted from the script under test and exercised directly, so this runs on
# every pull request.
# ---------------------------------------------------------------------------
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

failures=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  fail %s\n' "$1"; failures=$((failures + 1)); }

script=runtime/lib/firstboot.sh
unit=system_files/etc/systemd/system/agent-workspace-firstboot.service

echo "firstboot: provisioning is idempotent and survives an unmappable uid"

# ---------------------------------------------------------------------------
# 1. the script and its unit exist and are wired together
# ---------------------------------------------------------------------------
if [[ -r "${script}" ]]; then
  pass "${script} exists"
else
  fail "${script} is missing"
fi

if [[ -r "${unit}" ]]; then
  pass "${unit} exists"
else
  fail "${unit} is missing"
fi

# The marker is what makes firstboot idempotent: the unit must be guarded on it,
# or every boot re-provisions.
if [[ -r "${unit}" ]] && grep -q 'ConditionPathExists=.*\.provisioned' "${unit}"; then
  pass "the unit is guarded on the completion marker"
else
  fail "the unit does not guard on the completion marker"
fi

# ---------------------------------------------------------------------------
# 2. the marker is written unconditionally, as the last step
# ---------------------------------------------------------------------------
if grep -qE '^touch "\$MARKER"' "${script}"; then
  pass "the marker is written unconditionally"
else
  fail "the marker is not written unconditionally"
fi

# It must come after the ownership block, so that a best-effort chown cannot
# skip it. Compare line numbers rather than trusting the comment that says so.
marker_line="$(grep -nE '^touch "\$MARKER"' "${script}" | cut -d: -f1)"
owner_line="$(grep -n 'owned_failed' "${script}" | tail -1 | cut -d: -f1)"
if [[ -n "${marker_line}" && -n "${owner_line}" && "${marker_line}" -gt "${owner_line}" ]]; then
  pass "the marker is written after the ownership block (line ${marker_line} > ${owner_line})"
else
  fail "the marker is not written after the ownership block"
fi

# ---------------------------------------------------------------------------
# 3. ownership failure never aborts provisioning
# ---------------------------------------------------------------------------
# The chown call itself must not be bare under `set -e`.
if grep -qE 'if chown .*; then' "${script}"; then
  pass "chown is guarded so that failure cannot abort the unit"
else
  fail "chown is not guarded against failure"
fi

# ...and the "skipped because unmappable" path must not be counted as a failure.
if grep -q 'owned_skipped=\$((owned_skipped + 1))' "${script}"; then
  pass "an unmappable uid is counted as skipped, not failed"
else
  fail "an unmappable uid is not distinguished from a failure"
fi

# A blanket `|| true` on the chown would satisfy nothing above; make sure the
# distinction is real by requiring the warn path to exist alongside it.
if grep -q 'warn "could not set owner' "${script}"; then
  pass "a real ownership failure is reported, not swallowed"
else
  fail "a real ownership failure is not reported"
fi

# ---------------------------------------------------------------------------
# 4. id_is_mapped reads /proc/self/uid_map with the correct column order
# ---------------------------------------------------------------------------
# Extract the function from the script under test and evaluate it against
# modelled mapping files, so the assertion is on behaviour, not on the text.
extract_id_is_mapped() {
  awk '/^id_is_mapped\(\) \{/{flag=1} flag{print} flag && /^\}/{exit}' "${script}"
}

if [[ -n "$(extract_id_is_mapped)" ]]; then
  pass "id_is_mapped is extractable from ${script}"
else
  fail "id_is_mapped could not be extracted from ${script}"
fi

probe_dir="$(mktemp -d)"
trap 'rm -rf "${probe_dir}"' EXIT

# Exercise the real function body against a modelled /proc/self/uid_map.
# The body hardcodes the path, so run it in a subshell with the map substituted.
mapped() {
  local target="$1" mapfile="$2"
  local body
  body="$(extract_id_is_mapped)"
  body="${body//\/proc\/self\/uid_map/${mapfile}}"
  ( eval "${body}"; id_is_mapped "${target}" )
}

# Shape A: the common rootless single mapping. Only uid 0 is inside.
printf '         0       1000          1\n' > "${probe_dir}/single"
if mapped 0 "${probe_dir}/single"; then
  pass "single mapping 0/1000/1: uid 0 is addressable"
else
  fail "single mapping 0/1000/1: uid 0 is not addressable"
fi
if mapped 1000 "${probe_dir}/single"; then
  fail "single mapping 0/1000/1: uid 1000 is wrongly addressable (length read from the outside-id column)"
else
  pass "single mapping 0/1000/1: uid 1000 is not addressable"
fi

# Shape B: a real range. The length is the *third* column.
printf '      1001       1001      64535\n' > "${probe_dir}/range"
if mapped 1001 "${probe_dir}/range"; then
  pass "range 1001/1001/64535: the first uid is addressable"
else
  fail "range 1001/1001/64535: the first uid is not addressable"
fi
if mapped 3000 "${probe_dir}/range"; then
  pass "range 1001/1001/64535: an interior uid is addressable"
else
  fail "range 1001/1001/64535: an interior uid is not addressable (range truncated to the outside id)"
fi
if mapped 70000 "${probe_dir}/range"; then
  fail "range 1001/1001/64535: an out-of-range uid is wrongly addressable"
else
  pass "range 1001/1001/64535: an out-of-range uid is not addressable"
fi

# Shape C: several mappings, as this host actually reports.
printf '         0          1       1000\n      1000          0          1\n      1001       1001      64535\n' \
  > "${probe_dir}/multi"
if mapped 500 "${probe_dir}/multi"; then
  pass "multiple mappings: uid 500 is addressable"
else
  fail "multiple mappings: uid 500 is not addressable"
fi
if mapped 65000 "${probe_dir}/multi"; then
  pass "multiple mappings: uid 65000 is addressable"
else
  fail "multiple mappings: uid 65000 is not addressable"
fi

printf '\n'
if [[ "$failures" -eq 0 ]]; then
  echo "firstboot: all checks passed"
else
  echo "firstboot: ${failures} check(s) failed"
  exit 1
fi
