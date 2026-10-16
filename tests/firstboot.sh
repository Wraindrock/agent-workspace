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

# ---------------------------------------------------------------------------
# 5. the image's dsh plugin set reaches the agent's home
# ---------------------------------------------------------------------------
# The image ships a dsh profile (this project's default plugin set) under
# /usr/share/agent-workspace/dsh, but dsh reads profiles from the agent's own
# $HOME/.dsh -- inside the volume the installer mounts. firstboot is what moves
# one into the other, and every wrong decision it can make is silent:
#
#   * seeding after the completion marker lets the web UI start against a home
#     with no profile at all (the marker is what the readiness probe waits for);
#   * a wrong "already current" leaves a stale plugin set forever;
#   * a wrong "not mine, leave it" never delivers the plugins;
#   * a wrong "refresh" overwrites the one file that belongs to the user, the
#     cordis patch layer.
#
# The assertions below pin the ordering, the shipped shapes, and the four
# decisions against a fixture.
echo "firstboot: the image's dsh plugin set is seeded into the agent's home"

profile_lib=runtime/lib/dsh-profile.sh
profile_src=system_files/usr/share/agent-workspace/dsh/profiles
seed_module=build_files/modules/45-dsh-plugins/install.sh

if [[ -r "${profile_lib}" ]]; then
  pass "${profile_lib} exists"
else
  fail "${profile_lib} is missing"
fi

if grep -qF 'dsh-profile.sh' "${script}"; then
  pass "firstboot sources the profile library"
else
  fail "firstboot does not source the profile library"
fi

seed_line="$(grep -n 'seed_dsh_profiles "\$home"' "${script}" | cut -d: -f1)"
if [[ -n "${seed_line}" && -n "${marker_line}" && "${seed_line}" -lt "${marker_line}" ]]; then
  pass "the profile is seeded before the completion marker (line ${seed_line} < ${marker_line})"
else
  fail "the profile is not seeded before the completion marker"
fi

# A seeding failure is reported, never fatal: the marker must still be written
# or the container provisions itself again on every boot.
if grep -qE 'seed_dsh_profiles "\$home" .*\|\|$' "${script}"; then
  pass "a seeding failure cannot abort firstboot"
else
  fail "a seeding failure is not guarded"
fi

shopt -s nullglob
shipped_profiles=("${profile_src}"/*/)
shopt -u nullglob

if (( ${#shipped_profiles[@]} > 0 )); then
  pass "the image ships ${#shipped_profiles[@]} dsh profile(s)"
else
  fail "the image ships no dsh profile"
fi

for profile in "${shipped_profiles[@]}"; do
  profile_name="$(basename "${profile%/}")"
  for file in package.json pnpm-workspace.yaml pnpm-lock.yaml cordis.patch.yml; do
    if [[ -f "${profile}${file}" ]]; then
      pass "shipped profile ${profile_name}: ${file}"
    else
      fail "shipped profile ${profile_name} has no ${file}"
    fi
    # seed_dsh_profiles copies these into the agent's home with `cp -a`, so the
    # mode in the image is the mode the agent ends up with: keep them readable
    # and not writable by anyone but their owner.
    if [[ -f "${profile}${file}" ]] && [[ -r "${profile}${file}" ]] &&
      [[ -z "$(find "${profile}${file}" -perm /022 -print -quit)" ]]; then
      pass "shipped profile ${profile_name}: ${file} is readable and not group/world-writable"
    else
      fail "shipped profile ${profile_name}: ${file} is missing, unreadable, or group/world-writable"
    fi
  done

  # dsh resolves a bundle from the profile's own dependencies and, when it
  # cannot, skips it with nothing but a line on stderr: the container would
  # start and quietly run without that plugin. Every bundle this project adds
  # therefore has to be a dependency as well.
  bundles="$(sed -n '/"bundles": \[/,/\]/p' "${profile}package.json" |
    sed -n 's/^[[:space:]]*"\([^"]*\)",\{0,1\}$/\1/p')"
  deps="$(sed -n '/"dependencies": {/,/^[[:space:]]*}/p' "${profile}package.json" |
    tail -n +2 | sed -n 's/^[[:space:]]*"\([^"]*\)":.*$/\1/p')"
  undecleared=""
  for bundle in ${bundles}; do
    case "${bundle}" in
      @deepseek-ai/*) continue ;; # dsh ships its own bundles
    esac
    printf '%s\n' "${deps}" | grep -qxF -- "${bundle}" || undecleared="${undecleared} ${bundle}"
  done
  if [[ -z "${undecleared}" ]]; then
    pass "shipped profile ${profile_name}: every bundle it lists can be resolved"
  else
    fail "shipped profile ${profile_name} lists bundles that are not dependencies:${undecleared}"
  fi

  # The patch layer belongs to the user, so the project ships it empty.
  if [[ "$(grep -vE '^[[:space:]]*(#|$)' "${profile}cordis.patch.yml" | tr -d '[:space:]')" == "[]" ]]; then
    pass "shipped profile ${profile_name}: the patch layer ships empty"
  else
    fail "shipped profile ${profile_name} ships a non-empty patch layer"
  fi
done

# The behaviour of the seeding logic, against a fixture the size of the real
# one instead of the real 600 MB of dependencies.
seed_probe="$(mktemp -d)"
fixture_root="${seed_probe}/usr/share/agent-workspace/dsh/profiles"
fixture_profile="${fixture_root}/web"
install -d "${fixture_profile}/node_modules/fake-plugin"
printf '{"name":"dsh-profile-web","dependencies":{"fake-plugin":"1.0.0"}}\n' >"${fixture_profile}/package.json"
printf 'nodeLinker: hoisted\n' >"${fixture_profile}/pnpm-workspace.yaml"
printf 'lockfileVersion: 9.0\n' >"${fixture_profile}/pnpm-lock.yaml"
printf '# template\n[]\n' >"${fixture_profile}/cordis.patch.yml"
printf 'module.exports = 1\n' >"${fixture_profile}/node_modules/fake-plugin/index.js"
printf 'set1111111111\n' >"${seed_probe}/profiles.version"

seed_home="${seed_probe}/home/agent"
install -d "${seed_home}"

run_seed() { # run_seed [HOME] -- seed with the fixture and report log/warn lines
  local target="${1:-${seed_home}}"
  DSH_PROFILE_SRC="${fixture_root}" \
    DSH_PROFILE_VERSION_FILE="${seed_probe}/profiles.version" \
    bash -c 'log() { printf "log: %s\n" "$*"; }; warn() { printf "warn: %s\n" "$*"; };
      source "$1"; shift; seed_dsh_profiles "$@"' \
    _ "${profile_lib}" "${target}" "$(id -un)" 2>&1
}

seeded="${seed_home}/.dsh/profiles/web"
seed_rc=0
seed_out="$(run_seed)" || seed_rc=$?
if (( seed_rc == 0 )) && [[ -f "${seeded}/package.json" && -f "${seeded}/node_modules/fake-plugin/index.js" ]]; then
  pass "a fresh home gets the plugin set, dependencies included"
else
  fail "a fresh home was not seeded (rc=${seed_rc}): ${seed_out}"
fi
if [[ -f "${seeded}/cordis.patch.yml" ]]; then
  pass "the patch-layer template is seeded the first time"
else
  fail "the patch-layer template is not seeded"
fi
if grep -q '1 seeded' <<<"${seed_out}"; then
  pass "the seed is reported as a count, not as a bare success"
else
  fail "the seed is not reported as a count: ${seed_out}"
fi

# Idempotence: the same version must not touch the profile even when its source
# changed (the next image's digest will differ; this one has not).
printf 'unreleased\n' >"${fixture_profile}/package.json"
seed_rc=0
seed_out="$(run_seed)" || seed_rc=$?
if (( seed_rc == 0 )) && grep -q '1 current' <<<"${seed_out}" &&
  grep -q 'fake-plugin' "${seeded}/package.json" && ! grep -q 'unreleased' "${seeded}/package.json"; then
  pass "a second run at the same version leaves the profile alone"
else
  fail "a second run at the same version changed the profile (rc=${seed_rc}): ${seed_out}"
fi

# A refresh replaces what the image owns and keeps everything else, including
# the user's patch layer.
printf '# mine\n- id: some-plugin\n' >"${seeded}/cordis.patch.yml"
printf 'kept\n' >"${seeded}/notes.txt"
printf '{"name":"dsh-profile-web","dependencies":{"fake-plugin":"2.0.0"}}\n' >"${fixture_profile}/package.json"
printf 'module.exports = 2\n' >"${fixture_profile}/node_modules/fake-plugin/index.js"
printf 'set2222222222\n' >"${seed_probe}/profiles.version"
seed_rc=0
seed_out="$(run_seed)" || seed_rc=$?
if (( seed_rc == 0 )) && grep -q '1 refreshed' <<<"${seed_out}" &&
  grep -q '2.0.0' "${seeded}/package.json" &&
  grep -q 'module.exports = 2' "${seeded}/node_modules/fake-plugin/index.js"; then
  pass "a new plugin set refreshes the profile"
else
  fail "a new plugin set did not refresh the profile (rc=${seed_rc}): ${seed_out}"
fi
if [[ "$(cat "${seeded}/cordis.patch.yml")" == "# mine
- id: some-plugin" && -f "${seeded}/notes.txt" ]]; then
  pass "a refresh keeps the user's patch layer and their other files"
else
  fail "a refresh overwrote something in the profile that is not the image's"
fi

# ...and a file the user edited is never replaced, even by a new set.
printf '{"name":"mine"}\n' >"${seeded}/package.json"
printf 'set3333333333\n' >"${seed_probe}/profiles.version"
seed_rc=0
seed_out="$(run_seed)" || seed_rc=$?
if (( seed_rc == 0 )) && grep -q '1 kept' <<<"${seed_out}" &&
  grep -q 'differs from plugin set' <<<"${seed_out}" &&
  [[ "$(cat "${seeded}/package.json")" == '{"name":"mine"}' ]]; then
  pass "a profile the user changed is kept, and said so"
else
  fail "a changed profile was not kept (rc=${seed_rc}): ${seed_out}"
fi

# The version stamp alone must not stand in for the files: at the same version,
# an edited profile is reported the same way instead of being called current.
same_home="${seed_probe}/home/samedit"
install -d "${same_home}"
printf 'set5555555555\n' >"${seed_probe}/profiles.version"
run_seed "${same_home}" >/dev/null 2>&1 || true
printf '{"name":"edited-by-me"}\n' >"${same_home}/.dsh/profiles/web/package.json"
seed_rc=0
seed_out="$(run_seed "${same_home}")" || seed_rc=$?
if (( seed_rc == 0 )) && grep -q '1 kept' <<<"${seed_out}" &&
  [[ "$(cat "${same_home}/.dsh/profiles/web/package.json")" == '{"name":"edited-by-me"}' ]]; then
  pass "an edited profile at the same version is kept and named, not called current"
else
  fail "an edited profile at the same version was not reported (rc=${seed_rc}): ${seed_out}"
fi

# A profile this image did not create is left alone too -- unless it happens to
# be byte-identical to the shipped set, which is the one case where adopting it
# cannot lose anything.
foreign_home="${seed_probe}/home/foreign"
install -d "${foreign_home}/.dsh/profiles/web"
printf '{"name":"theirs"}\n' >"${foreign_home}/.dsh/profiles/web/package.json"
seed_rc=0
seed_out="$(run_seed "${foreign_home}")" || seed_rc=$?
if (( seed_rc == 0 )) && grep -q 'this image did not create it' <<<"${seed_out}" &&
  [[ "$(cat "${foreign_home}/.dsh/profiles/web/package.json")" == '{"name":"theirs"}' ]] &&
  [[ ! -f "${foreign_home}/.dsh/profiles/web/.agent-workspace-profile" ]]; then
  pass "a foreign profile is left alone, with nothing recorded about it"
else
  fail "a foreign profile was not left alone (rc=${seed_rc}): ${seed_out}"
fi

adopted_home="${seed_probe}/home/adopter"
install -d "${adopted_home}/.dsh/profiles"
cp -a "${fixture_profile}" "${adopted_home}/.dsh/profiles/web"
printf 'set4444444444\n' >"${seed_probe}/profiles.version"
seed_rc=0
seed_out="$(run_seed "${adopted_home}")" || seed_rc=$?
if (( seed_rc == 0 )) && grep -q '1 adopted' <<<"${seed_out}" &&
  grep -q 'set4444444444' "${adopted_home}/.dsh/profiles/web/.agent-workspace-profile"; then
  pass "an identical pre-existing profile is adopted, so a later set reaches it"
else
  fail "an identical pre-existing profile was not adopted (rc=${seed_rc}): ${seed_out}"
fi

# Without a version stamp the image cannot tell whether its set is current, so
# the failure has to be reported rather than guessed at.
rm -f "${seed_probe}/profiles.version"
seed_rc=0
seed_out="$(run_seed)" || seed_rc=$?
if (( seed_rc == 1 )) && grep -q 'without a version stamp' <<<"${seed_out}"; then
  pass "a missing version stamp fails instead of seeding blind"
else
  fail "a missing version stamp did not fail (rc=${seed_rc}): ${seed_out}"
fi

rm -rf "${seed_probe}"

# The set is materialised during the build, where the lockfile -- not the
# network at container start -- decides what ships.
if [[ -x "${seed_module}" ]]; then
  pass "${seed_module} exists and is executable"
else
  fail "${seed_module} is missing or not executable"
fi
if grep -q -- '--frozen-lockfile' "${seed_module}"; then
  pass "the build installs the plugin set from the lockfile"
else
  fail "the build does not pin the plugin set to the lockfile"
fi
if grep -q 'skipping profile bundle' "${seed_module}"; then
  pass "the build asserts the set composes instead of trusting an exit code"
else
  fail "the build does not assert that the set composes"
fi

printf '\n'
if [[ "$failures" -eq 0 ]]; then
  echo "firstboot: all checks passed"
else
  echo "firstboot: ${failures} check(s) failed"
  exit 1
fi
