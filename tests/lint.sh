#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Repository self check. Runs on every pull request and locally via
# `just check`. Deliberately dependency-light: bash, grep and coreutils,
# with optional shellcheck / jq / python3 upgrades when they are available.
# ---------------------------------------------------------------------------
set -euo pipefail

cd "$(dirname "$0")/.."

failures=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  fail %s\n' "$1"; failures=$((failures + 1)); }

# bash scripts get a syntax check and, when available, shellcheck.
# The Justfile is not a shell script and is deliberately not listed here.
shell_files=()
while IFS= read -r file; do shell_files+=("$file"); done < <(
  find . -path ./.git -prune -o -type f -name '*.sh' -print | sort
)
# the runtime CLI is a bash script without the .sh suffix
[[ -f runtime/bin/agent-workspace ]] && shell_files+=(runtime/bin/agent-workspace)

echo "shell syntax"
for file in "${shell_files[@]}"; do
  if bash -n "$file"; then
    pass "$file"
  else
    fail "$file (bash -n)"
  fi
done

if command -v shellcheck >/dev/null 2>&1; then
  echo "shellcheck"
  if shellcheck --severity=warning --external-sources "${shell_files[@]}"; then
    pass "shellcheck"
  else
    fail "shellcheck (see diagnostics above)"
  fi
else
  echo "shellcheck"
  pass "shellcheck not installed, skipped"
fi

echo "module contract"
shopt -s nullglob
for dir in build_files/modules/*/; do
  name="$(basename "${dir%/}")"
  if [[ ! -f "${dir}module.env" ]]; then
    fail "${name}: missing module.env"
    continue
  fi
  if [[ ! -x "${dir}install.sh" ]]; then
    fail "${name}: install.sh missing or not executable"
    continue
  fi
  if ! grep -qE "^MODULE_NAME=\"?${name}\"?$" "${dir}module.env"; then
    fail "${name}: MODULE_NAME does not match the directory name"
    continue
  fi
  if ! grep -qE '^MODULE_ENABLED_DEFAULT="?[01]"?$' "${dir}module.env"; then
    fail "${name}: MODULE_ENABLED_DEFAULT must be 0 or 1"
    continue
  fi
  # module.env is sourced by build_files/build.sh: unquoted values containing
  # spaces would be executed as commands instead of assigned.
  # shellcheck disable=SC1090 # the module.env path is computed per module
  if ! ( set -euo pipefail; source "${dir}module.env"; [[ -n "${MODULE_NAME}" && -n "${MODULE_DESCRIPTION}" ]] ); then
    fail "${name}: module.env is not sourceable by bash, quote values that contain spaces"
    continue
  fi
  pass "module ${name}"
done
shopt -u nullglob

echo "declarative config"
modules="$(sed 's/#.*//' config/modules.conf | grep -E '^[a-z0-9-]+=' | cut -d= -f1 | sort -u)"
for module in $modules; do
  if [[ -d "build_files/modules/${module}" ]]; then
    pass "config/modules.conf: ${module}"
  else
    fail "config/modules.conf references unknown module ${module}"
  fi
done

agents="$(sed 's/#.*//' config/agents.conf | grep -E '^[a-z0-9-]+=' | cut -d= -f1 | sort -u)"
for agent in $agents; do
  if [[ -f "build_files/modules/40-agent-harnesses/agents/${agent}.sh" ]]; then
    pass "config/agents.conf: ${agent}"
  else
    fail "config/agents.conf references unknown agent recipe ${agent}"
  fi
done

echo "image.env"
if bash -c 'set -euo pipefail; . ./image.env; [ -n "${IMAGE_NAME}" ] && [ -n "${BASE_IMAGE}" ]'; then
  pass "image.env is sourceable by bash and defines IMAGE_NAME and BASE_IMAGE"
else
  fail "image.env cannot be sourced by bash (quote values that contain spaces)"
fi

echo "required files"
for required in Containerfile Justfile image.env LICENSE README.md docs/architecture.md docs/rollback.md; do
  if [[ -e "$required" ]]; then
    pass "$required"
  else
    fail "$required missing"
  fi
done

echo "config formats"
# renovate.json5 is JSON5 (comments and trailing commas), so jq cannot parse it.
# The strict YAML/JSON files are validated in the next section.
if [[ -s .github/renovate.json5 ]]; then
  pass ".github/renovate.json5 present (JSON5, not validated by jq)"
else
  fail ".github/renovate.json5 missing or empty"
fi

echo "yaml"
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
  for yaml_file in .github/workflows/*.yml .github/dependabot.yml .github/ISSUE_TEMPLATE/*.yml; do
    [[ -e "$yaml_file" ]] || continue
    if python3 -c "import sys, yaml; yaml.safe_load(open(sys.argv[1]))" "$yaml_file" 2>/dev/null; then
      pass "$yaml_file"
    else
      fail "$yaml_file (invalid yaml)"
    fi
  done
else
  pass "python3/pyyaml not installed, skipped"
fi

echo
if [[ "$failures" -eq 0 ]]; then
  echo "lint: all checks passed"
else
  echo "lint: ${failures} check(s) failed"
  exit 1
fi
