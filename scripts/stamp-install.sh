#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Stamp the bootstrap checksums in install.sh.
#
# `install.sh | bash` installs without a checkout, so the script fetches
# installer/lib/*.sh and image.env at run time. It verifies them against digests
# carried inside install.sh itself - that anchor is the whole point, because a
# manifest downloaded alongside the files could be replaced together with them.
#
# That makes install.sh a generated artifact in exactly one respect: the two
# BOOTSTRAP_SHA256_* tables. This script regenerates them from the working tree.
#
#   scripts/stamp-install.sh          # rewrite the tables in place
#   scripts/stamp-install.sh --check  # exit 1 if they are out of date
#
# `just stamp` runs it; `just check` and `tests/lint.sh` run --check, so a commit
# that edits installer/lib without re-stamping fails CI instead of shipping a
# script whose checksums do not match the files it is supposed to verify.
#
# Both refs carry the same table on purpose. `main` and `dev` hold identical
# content at the moment a change lands on both; when they diverge, each branch's
# own install.sh carries its own digests, which is correct - a `dev` bootstrap
# verifies against dev's files.
# ---------------------------------------------------------------------------
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
install_sh="${repo_root}/install.sh"

files=(
  image.env
  installer/lib/agents.sh
  installer/lib/commands.sh
  installer/lib/engine.sh
  installer/lib/state.sh
  installer/lib/ui.sh
)

check_only=0
case "${1:-}" in
  --check) check_only=1 ;;
  "" ) ;;
  *) echo "usage: scripts/stamp-install.sh [--check]" >&2; exit 2 ;;
esac

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    echo "need sha256sum or shasum" >&2
    exit 1
  fi
}

[[ -f "$install_sh" ]] || { echo "missing $install_sh" >&2; exit 1; }

# Build the two replacement tables, then compare or splice.
build_table() {
  local name="$1" file digest
  printf 'declare -A %s=(\n' "$name"
  for file in "${files[@]}"; do
    [[ -f "${repo_root}/${file}" ]] || { echo "missing ${file}" >&2; exit 1; }
    digest="$(sha256_of "${repo_root}/${file}")"
    printf '  [%s]="%s"\n' "$file" "$digest"
  done
  printf ')\n'
}

new_main="$(build_table BOOTSTRAP_SHA256_MAIN)"
new_dev="$(build_table BOOTSTRAP_SHA256_DEV)"

# Replace the body of each table, keeping everything else byte-identical.
replace_table() {
  local name="$1" body="$2" tmp
  tmp="$(mktemp)"
  # The table runs from `declare -A NAME=(` to the first line that is exactly `)`.
  awk -v name="$name" -v body="$body" '
    $0 ~ "^declare -A " name "=\\(" { print body; skipping = 1; next }
    skipping && $0 == ")" { skipping = 0; next }
    skipping { next }
    { print }
  ' "$install_sh" > "$tmp"
  mv "$tmp" "$install_sh"
}

current_main="$(sed -n '/^declare -A BOOTSTRAP_SHA256_MAIN=(/,/^)/p' "$install_sh")"
current_dev="$(sed -n '/^declare -A BOOTSTRAP_SHA256_DEV=(/,/^)/p' "$install_sh")"

if [[ "$current_main" == "$new_main" && "$current_dev" == "$new_dev" ]]; then
  if [[ "$check_only" -eq 1 ]]; then
    echo "install.sh bootstrap checksums are up to date"
    exit 0
  fi
  echo "install.sh bootstrap checksums already up to date"
  exit 0
fi

if [[ "$check_only" -eq 1 ]]; then
  echo "install.sh bootstrap checksums are STALE" >&2
  echo "run: just stamp   (scripts/stamp-install.sh)" >&2
  echo >&2
  echo "--- expected ---" >&2
  printf '%s\n' "$new_main" >&2
  echo "--- found ---" >&2
  printf '%s\n' "$current_main" >&2
  exit 1
fi

replace_table BOOTSTRAP_SHA256_MAIN "$new_main"
replace_table BOOTSTRAP_SHA256_DEV "$new_dev"
echo "stamped install.sh bootstrap checksums for ${#files[@]} files"
