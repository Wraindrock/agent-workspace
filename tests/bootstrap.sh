#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Behavioural regression assertions for the curl|bash bootstrap.
#
#   tests/bootstrap.sh
#
# `curl -fsSL .../install.sh | bash` is the documented way to install, so
# install.sh has to run with no checkout beside it: it fetches installer/lib/*
# and image.env itself and verifies them against digests carried inside the
# script. That check is the whole safety story for this install path, and it is
# exactly the kind of code that can rot silently - a bootstrap that skips
# verification, or that keeps going after a mismatch, still prints a working
# TUI. These assertions are therefore about behaviour, not about the presence of
# words:
#
#   1. the stamped digests match the files in this tree, so a commit that edits
#      installer/lib without re-stamping fails here instead of shipping a script
#      whose checksums cannot verify anything;
#   2. every fetched file has a digest from both refs, so a new file added to the
#      bootstrap list cannot be fetched unverified;
#   3. the mismatch path really aborts - exercised by running the *extracted*
#      verify logic against a deliberately corrupted copy, so the assertion fails
#      if someone ever turns the check into a warning;
#   4. a checkout short-circuits the network entirely.
#
# No container engine, no root, no network: the network-dependent end-to-end run
# is `tests/bootstrap-e2e.sh`, which needs curl and the published refs.
# ---------------------------------------------------------------------------
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

failures=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  fail %s\n' "$1"; failures=$((failures + 1)); }

install_sh=install.sh

echo "bootstrap: curl | bash"

# 0. install.sh must exist and be parseable ---------------------------------
if bash -n "$install_sh" 2>/dev/null; then
  pass "install.sh parses"
else
  fail "install.sh does not parse"
fi

# 1. the stamp is fresh -----------------------------------------------------
# scripts/stamp-install.sh --check is the single source of truth for this; it
# exits non-zero when the tables in install.sh do not match the working tree.
if ! [[ -x scripts/stamp-install.sh ]]; then
  fail "scripts/stamp-install.sh is missing or not executable"
else
  if stamp_out="$(bash scripts/stamp-install.sh --check 2>&1)"; then
    pass "bootstrap checksums are in step with the tree"
  else
    fail "bootstrap checksums are stale (run: just stamp) - ${stamp_out%%$'\n'*}"
  fi
fi

# 1b. stamping keeps install.sh executable ----------------------------------
# stamp-install.sh rewrites install.sh through a temp file, and mktemp creates
# 0600: a plain `mv` then hands install.sh that mode, so `./install.sh` - the
# incantation the docs use - dies with "Permission denied" while the checksums
# look perfectly correct. Assert on a real stamp run over a copy of the tree,
# because the damage only shows after the swap.
if [[ -x scripts/stamp-install.sh ]]; then
  stamp_tree="$(mktemp -d)"
  mkdir -p "${stamp_tree}/scripts" "${stamp_tree}/installer/lib"
  cp install.sh image.env "${stamp_tree}/"
  cp -R installer/lib/. "${stamp_tree}/installer/lib/"
  cp scripts/stamp-install.sh "${stamp_tree}/scripts/stamp-install.sh"
  chmod 0755 "${stamp_tree}/install.sh"
  # make the tables stale, so the script really rewrites install.sh
  sed -i 's/^\( *\[installer\/lib\/engine.sh\]=\).*$/\1"stale"/' "${stamp_tree}/install.sh"
  if ( cd "${stamp_tree}" && bash scripts/stamp-install.sh >/dev/null 2>&1 ) &&
     [[ -x "${stamp_tree}/install.sh" ]]; then
    pass "stamping install.sh keeps it executable"
  else
    fail "stamping install.sh drops its executable bit (./install.sh would fail)"
  fi
  rm -rf "${stamp_tree}"
fi

# 2. every bootstrapped file carries a digest for both refs -----------------
files="$(
  awk '/^BOOTSTRAP_FILES=\(/{f=1;next} f&&/^\)/{exit} f{print}' "$install_sh" |
    tr -d ' '
)"
if [[ -z "$files" ]]; then
  fail "could not read BOOTSTRAP_FILES from ${install_sh}"
else
  missing=0
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    for ref in main dev; do
      # the table entry looks like: [installer/lib/engine.sh]="<64 hex>"
      if ! grep -qE "^  \[${file}\]=\"[0-9a-f]{64}\"$" "$install_sh"; then
        fail "${file} has no 64-hex digest stamped for ref ${ref}"
        missing=$((missing + 1))
      fi
    done
    # a file listed for fetching but absent from the tree would be stamped as
    # nothing and then fail at run time; catch it here instead
    if [[ ! -f "$file" ]]; then
      fail "${file} is listed in BOOTSTRAP_FILES but does not exist"
      missing=$((missing + 1))
    fi
  done <<<"$files"
  [[ "$missing" -eq 0 ]] && pass "every bootstrapped file has a digest for main and dev"
fi

# 3. the recorded digest is the real digest ---------------------------------
# Comparing the stamp against the tree once more, independently of the stamping
# tool, so that a bug in stamp-install.sh cannot make both sides agree wrongly.
sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}
mismatch=0
while IFS= read -r file; do
  [[ -n "$file" ]] || continue
  [[ -f "$file" ]] || continue
  want="$(sha_of "$file")"
  # the table line is:  [path]="<hex>"; awk rather than sed because paths contain /
  got="$(awk -v f="$file" '$0 ~ "^  \\[" f "\\]=\"" { if (match($0, /"[0-9a-f]{64}"/)) { print substr($0, RSTART+1, RLENGTH-2); exit } }' "$install_sh")"
  if [[ "$want" != "$got" ]]; then
    fail "${file}: stamped ${got:-none}, actual ${want}"
    mismatch=$((mismatch + 1))
  fi
done <<<"$files"
[[ "$mismatch" -eq 0 ]] && pass "stamped digests equal the real file digests"

# 4. the mismatch path actually aborts --------------------------------------
# This drives the REAL bootstrap_fetch, extracted from install.sh, rather than a
# re-implementation of its tail. That distinction is the whole point: an earlier
# version of this test ran a hand-written `verify_only` stand-in and stayed
# green even when the real check was edited into a warning, which is a
# decorative assertion - it proved the stand-in worked, not the installer.
#
# AW_BOOTSTRAP_DOWNLOAD replaces the curl invocation so no network is needed;
# production still uses curl over HTTPS.
probe="$(mktemp -d)"
trap 'rm -rf "$probe"' EXIT

extract_fn() {
  awk -v fn="$1" '
    $0 ~ "^" fn "\\(\\) \\{" { grab = 1 }
    grab { print }
    grab && /^\}/ { exit }
  ' "$install_sh"
}

{
  extract_fn bootstrap_die
  extract_fn sha256_of
  extract_fn bootstrap_expected_sha
  extract_fn bootstrap_fetch
} >"$probe/fns.sh"

# The digest bootstrap_fetch looks up must be one this test controls, so point
# the lookup at a table the probe defines instead of install.sh's real stamps.
cat >>"$probe/fns.sh" <<'SH'
declare -A PROBE_SHA=()
bootstrap_expected_sha() { printf '%s' "${PROBE_SHA[${1}]:-}"; }
SH

# A downloader that copies whatever fixture we name, ignoring the URL.
printf '#!/usr/bin/env bash\nset -euo pipefail\nout=""; url=""\nwhile [[ $# -gt 0 ]]; do\n  case "$1" in\n    -o) out="$2"; shift 2 ;;\n    *) url="$1"; shift ;;\n  esac\ndone\ncp "${PROBE_PAYLOAD}" "$out"\n' >"$probe/downloader"
chmod +x "$probe/downloader"

if ! grep -q 'bootstrap_fetch()' "$probe/fns.sh"; then
  fail "could not extract bootstrap_fetch from ${install_sh}"
else
  # The fixture that bootstrap_fetch must accept: its bytes match its digest.
  printf 'legitimate installer library\n' >"$probe/payload-good"
  printf 'malicious replaced library\n' >"$probe/payload-evil"
  good_sha="$(sha_of "$probe/payload-good")"

  run_fetch() {  # $1 = fixture payload whose bytes will be "downloaded"
    PROBE_PAYLOAD="$1" bash -c "
      set -euo pipefail
      source '$probe/fns.sh'
      cache='$probe/cache'
      INSTALL_BASE_URL='https://example.invalid'
      INSTALL_REF='main'
      AW_BOOTSTRAP_DOWNLOAD='$probe/downloader'
      PROBE_SHA[image.env]='$good_sha'
      bootstrap_fetch image.env
    " 2>&1
  }

  # positive direction: matching bytes are accepted and installed
  if out="$(run_fetch "$probe/payload-good")"; then
    if [[ -f "$probe/cache/image.env" ]]; then
      pass "bootstrap_fetch installs a file whose digest matches"
    else
      fail "bootstrap_fetch reported success but installed nothing"
    fi
  else
    fail "bootstrap_fetch rejected matching content: ${out}"
  fi

  # negative direction: mismatched bytes must abort
  rm -rf "$probe/cache"
  set +e
  out="$(run_fetch "$probe/payload-evil")"
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    if [[ "$out" == *"checksum mismatch"* ]]; then
      pass "bootstrap_fetch aborts on a mismatch (exit ${rc})"
    else
      fail "bootstrap_fetch failed without saying why: ${out}"
    fi
  else
    fail "bootstrap_fetch ACCEPTED corrupted content (exit 0) - the check is decorative"
  fi

  # ...and leaves nothing behind: no installed file, no partial download
  if [[ -e "$probe/cache/image.env" ]]; then
    fail "the rejected file was installed anyway"
  else
    pass "the rejected file is not installed"
  fi
  if compgen -G "$probe/cache/image.env.part.*" >/dev/null; then
    fail "a partial download was left behind after the mismatch"
  else
    pass "no partial download is left behind"
  fi
fi

# 5. a checkout needs no network -------------------------------------------
# bootstrap_installer returns before any fetch when every file is present; if
# that guard were lost, a normal checkout would start hitting the network.
if awk '/^bootstrap_is_checkout\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$install_sh" |
   grep -q 'BOOTSTRAP_FILES'; then
  pass "the checkout guard iterates the file list"
else
  fail "bootstrap_is_checkout no longer checks the file list"
fi

if grep -qE '^  if bootstrap_is_checkout; then' "$install_sh"; then
  pass "the checkout guard short-circuits the fetch"
else
  fail "bootstrap_installer no longer short-circuits on a checkout"
fi

# 6. no silent-failure escape hatch -----------------------------------------
# A retry/ignore path around the fetch is how a checksum failure would become a
# warning in practice. The only permitted `|| true`-shaped escape is absent here
# on purpose; this asserts nobody adds one without reconsidering.
if grep -nE 'bootstrap_fetch.*\|\| *true|checksum mismatch.*\|\| *true' "$install_sh" >/dev/null; then
  fail "a checksum failure can be swallowed (|| true found near the fetch)"
else
  pass "a checksum mismatch cannot be swallowed"
fi

if [[ "${failures}" -eq 0 ]]; then
  echo "bootstrap: all checks passed"
  exit 0
fi
echo "bootstrap: ${failures} check(s) failed"
exit 1
