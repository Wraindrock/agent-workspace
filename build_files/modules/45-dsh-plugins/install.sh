#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../lib/common.sh
source "${COMMON_LIB:?COMMON_LIB must point at build_files/lib/common.sh}"

# ---------------------------------------------------------------------------
# The project's default dsh plugin set.
#
# The profile sources -- package.json (the bundles), pnpm-workspace.yaml, the
# lockfile and the empty patch-layer template -- arrive through the
# system_files overlay. What is left is the 600 MB of dependencies: this module
# installs them from the lockfile so that an agent container can load the set
# with no network at all, and so that the set an image ships is the set the
# lockfile in this repository reviews.
#
# Nothing here is copied into an agent's home. runtime/lib/firstboot.sh seeds
# the profile into $HOME/.dsh/profiles and runtime/lib/dsh-profile.sh decides
# there whether to seed, refresh or leave an existing profile alone.
# ---------------------------------------------------------------------------

DSH_PROFILE_ROOT="${DSH_PROFILE_ROOT:-/usr/share/agent-workspace/dsh/profiles}"
DSH_PROFILE_VERSION_FILE="${DSH_PROFILE_VERSION_FILE:-/usr/share/agent-workspace/dsh/profiles.version}"
# pnpm's store belongs under the build-time cache root: left at its default it
# lands in the build HOME (the ostree /root -> /var/roothome symlink), which
# means the install doubles its footprint and `bootc container lint` has to
# complain about undeclared /var content.
PNPM_STORE_DIR="${PNPM_STORE_DIR:-/var/cache/agent-workspace/pnpm-store}"

require_command pnpm
require_command node
require_command sha256sum

install -d -m 0755 "$PNPM_STORE_DIR"

# version_digest identifies the plugin set an image ships. It covers the three
# files that decide what an agent loads, and nothing else: the dsh installation
# versions the first-party bundles itself, and the patch layer is the user's.
# firstboot seeds a profile that is missing and refreshes one whose recorded
# digest differs, so the digest changes exactly when this project changes the
# set.
version_digest() {
  local dir name file digest
  {
    for dir in "$@"; do
      name="$(basename "${dir%/}")"
      for file in package.json pnpm-workspace.yaml pnpm-lock.yaml; do
        [[ -f "${dir}/${file}" ]] || continue
        digest="$(sha256sum "${dir}/${file}")"
        printf '%s/%s %s\n' "$name" "$file" "${digest%% *}"
      done
    done
  } | LC_ALL=C sort | sha256sum | awk '{ print substr($1, 1, 12) }'
}

# compose_check is the assertion that the set actually loads. `dsh --dump-config`
# exits 0 even when it has to skip a bundle it cannot resolve (the skip is only
# a line on stderr), so the exit code alone would be a false green: the check
# additionally requires that nothing was skipped and that every bundle the
# profile declares appears in the composed tree.
compose_check() {
  local dir="$1" name="$2"
  local probe out err bundles bundle missing=0
  probe="$(mktemp -d)"
  install -d -m 0755 "${probe}/dsh/profiles"
  ln -s "$dir" "${probe}/dsh/profiles/${name}"
  out="${probe}/composed.txt"
  err="${probe}/stderr.txt"

  if ! HOME="$probe" DSH_HOME="${probe}/dsh" dsh --profile "$name" --dump-config >"$out" 2>"$err"; then
    sed 's/^/  /' "$err" >&2
    rm -rf "$probe"
    die "dsh could not compose the ${name} profile"
  fi
  if [[ -s "$err" ]]; then
    sed 's/^/  /' "$err" >&2
  fi
  if grep -q 'skipping profile bundle' "$err"; then
    rm -rf "$probe"
    die "the ${name} profile cannot resolve every bundle it declares (see the skips above)"
  fi

  bundles="$(node -e 'const p = require(process.argv[1]); process.stdout.write((p.dsh?.profile?.bundles ?? []).join("\n"))' "${dir}/package.json")"
  while IFS= read -r bundle; do
    [[ -n "$bundle" ]] || continue
    if ! grep '^# == ' "$out" | grep -qF -- "$bundle"; then
      warn "bundle ${bundle} is missing from the composed ${name} profile"
      missing=1
    fi
  done <<<"$bundles"

  rm -rf "$probe"
  (( missing == 0 ))
}

shopt -s nullglob
profiles=("${DSH_PROFILE_ROOT}"/*/)
shopt -u nullglob
(( ${#profiles[@]} > 0 )) || die "no dsh profiles to install under ${DSH_PROFILE_ROOT}"

for dir in "${profiles[@]}"; do
  name="$(basename "${dir%/}")"
  [[ -f "${dir}/package.json" ]] || die "shipped dsh profile ${name} has no package.json"
  [[ -f "${dir}/pnpm-lock.yaml" ]] || die "shipped dsh profile ${name} has no pnpm-lock.yaml"
  section "dsh profile ${name}"
  # --frozen-lockfile: the lockfile is the reviewable input, so a dependency
  # that drifted since it was generated must fail the build rather than quietly
  # ship something else.
  ( cd "$dir" && retry 3 pnpm install --frozen-lockfile --store-dir "$PNPM_STORE_DIR" --reporter=append-only )
  [[ -d "${dir}/node_modules" ]] || die "pnpm installed no node_modules for the ${name} profile"
  compose_check "$dir" "$name" || die "the ${name} plugin set does not compose"
  ok "dsh profile ${name}: composes, $(du -sh "${dir}/node_modules" | cut -f1) of dependencies"
done

digest="$(version_digest "${profiles[@]}")"
printf '%s\n' "$digest" >"$DSH_PROFILE_VERSION_FILE"
chmod 0644 "$DSH_PROFILE_VERSION_FILE"
record_value tool "dsh plugin set ${digest}"
ok "dsh plugin set ${digest} installed under ${DSH_PROFILE_ROOT}"
