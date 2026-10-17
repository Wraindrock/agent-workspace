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
# bash scripts without the .sh suffix
for suffixless in runtime/bin/agent-workspace install.sh; do
  [[ -f "$suffixless" ]] && shell_files+=("$suffixless")
done

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

echo "actionlint"
if command -v actionlint >/dev/null 2>&1; then
  workflows=()
  while IFS= read -r wf; do workflows+=("$wf"); done < <(
    find .github/workflows -type f \( -name '*.yml' -o -name '*.yaml' \) | sort
  )
  if [[ "${#workflows[@]}" -eq 0 ]]; then
    pass "no workflow files to check"
  elif actionlint "${workflows[@]}"; then
    pass "actionlint"
  else
    fail "actionlint (see diagnostics above)"
  fi
else
  pass "actionlint not installed, skipped"
fi

echo "justfile"
if command -v just >/dev/null 2>&1; then
  # Parsing is the check that matters: a broken alias or an unescaped {{ }}
  # in a recipe body only shows up when someone runs just.
  if just --list >/dev/null; then
    pass "Justfile parses (just --list)"
  else
    fail "Justfile does not parse (see diagnostics above)"
  fi
else
  pass "just not installed, skipped"
fi

echo "installer"
# install.sh is exercised against a fake podman, so this needs neither root nor
# a container engine: it asserts the commands, files and exit codes.
installer_log="$(mktemp)"
if bash tests/install.sh >"$installer_log" 2>&1; then
  pass "tests/install.sh: $(tail -n 1 "$installer_log")"
else
  sed 's/^/  /' "$installer_log"
  fail "tests/install.sh (see output above)"
fi
rm -f "$installer_log"

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

echo "agent recipes"
recipes=()
while IFS= read -r recipe; do recipes+=("$recipe"); done < <(
  find build_files/modules/40-agent-harnesses/agents -type f -name '*.sh' | sort
)
for recipe in "${recipes[@]}"; do
  name="$(basename "${recipe%.sh}")"
  if ! grep -qE '^install_agent\(\) \{' "$recipe"; then
    fail "${name}: agent recipe does not define install_agent()"
    continue
  fi
  # The recipe name is not the command it installs (claude-code -> claude), so
  # every recipe must declare the binaries it provides.
  if ! grep -qE '^AGENT_BINARIES="[^"]+"$' "$recipe"; then
    fail "${name}: agent recipe must declare AGENT_BINARIES=\"<command>\""
    continue
  fi
  # The installer menu is built from these two, so a missing one would silently
  # drop the agent's label or its credential prompt.
  if ! grep -qE '^AGENT_TITLE="[^"]+"$' "$recipe"; then
    fail "${name}: agent recipe must declare AGENT_TITLE=\"<menu label>\""
    continue
  fi
  if ! grep -qE '^AGENT_ENV="[^"]+"$' "$recipe"; then
    fail "${name}: agent recipe must declare AGENT_ENV=\"<CREDENTIAL_VAR>\""
    continue
  fi
  pass "recipe ${name} (${name} -> $(sed -n 's/^AGENT_BINARIES="\([^"]*\)"$/\1/p' "$recipe"))"
done

echo "image.env"
if bash -c 'set -euo pipefail; . ./image.env; [ -n "${IMAGE_NAME}" ] && [ -n "${BASE_IMAGE}" ]'; then
  pass "image.env is sourceable by bash and defines IMAGE_NAME and BASE_IMAGE"
else
  fail "image.env cannot be sourced by bash (quote values that contain spaces)"
fi

echo "required files"
for required in Containerfile Justfile install.sh image.env LICENSE README.md \
  docs/architecture.md docs/rollback.md docs/containers.md \
  installer/lib/engine.sh installer/lib/state.sh installer/lib/ui.sh \
  installer/lib/agents.sh installer/lib/commands.sh \
  installer/lib/backend-container-cli.sh installer/lib/backend-podman.sh \
  installer/lib/backend-docker.sh installer/lib/backend-incus.sh \
  system_files/usr/share/agent-workspace/dsh-web.yml \
  runtime/lib/dsh-profile.sh \
  system_files/usr/share/agent-workspace/dsh/profiles/web/package.json \
  system_files/usr/share/agent-workspace/dsh/profiles/web/pnpm-workspace.yaml \
  system_files/usr/share/agent-workspace/dsh/profiles/web/pnpm-lock.yaml \
  system_files/usr/share/agent-workspace/dsh/profiles/web/cordis.patch.yml \
  tests/install.sh tests/fixtures/fake-engine.sh; do
  if [[ -e "$required" ]]; then
    pass "$required"
  else
    fail "$required missing"
  fi
done

echo "the documented entry point runs"
# Every doc says `./install.sh`, so the file has to carry the executable bit --
# a clone that cannot run the one entry point is a defect no other check sees
# (the bootstrap's `curl -o install.sh && bash install.sh` form does not need it,
# which is exactly how it went unnoticed).
if [[ -x install.sh ]]; then
  pass "install.sh is executable (the docs invoke it as ./install.sh)"
else
  fail "install.sh is not executable, but the docs invoke it as ./install.sh"
fi

echo "installer structure"
for symbol in "create_container_from" "cmd_list" "cmd_enter" "cmd_snapshot" "cmd_rollback" "cmd_recover" "cmd_fork" "cmd_upgrade" "cmd_remove" "cmd_doctor" "cmd_web" "cmd_root"; do
  if grep -qE "^${symbol}\(\) \{" installer/lib/commands.sh; then
    pass "installer/lib/commands.sh defines ${symbol}"
  else
    fail "installer/lib/commands.sh does not define ${symbol}"
  fi
done
for symbol in "run_engine" "backend_load" "resolve_engine" "detect_engines" "eng_host_port"; do
  if grep -qE "^${symbol}\(\) \{" installer/lib/engine.sh; then
    pass "installer/lib/engine.sh defines ${symbol}"
  else
    fail "installer/lib/engine.sh does not define ${symbol}"
  fi
done
# The verbs are the backend interface; the container-CLI backends share one
# implementation, so their verbs must live in backend-container-cli.sh (the
# per-backend files only override what differs).
for symbol in "eng_create_persistent" "eng_create_ephemeral" "eng_exec" "eng_exec_test" "eng_exec_background" "eng_exec_capture" "eng_volume_create" "eng_volume_archive" "eng_volume_restore_archive" "eng_volume_clone"; do
  if grep -qE "^${symbol}\(\)[[:space:]]*\{" installer/lib/backend-container-cli.sh; then
    pass "installer/lib/backend-container-cli.sh defines ${symbol}"
  else
    fail "installer/lib/backend-container-cli.sh does not define ${symbol}"
  fi
done
# The flags that boot systemd differ per container CLI, so each of them owns that
# one verb; a backend without it cannot create a workspace at all.
for backend in podman docker; do
  if grep -qE "^eng_run_flags\(\)[[:space:]]*\{" "installer/lib/backend-${backend}.sh"; then
    pass "installer/lib/backend-${backend}.sh defines eng_run_flags"
  else
    fail "installer/lib/backend-${backend}.sh does not define eng_run_flags"
  fi
done
# Incus is not a container CLI: its instances, images and mounts are daemon
# objects, so it implements the whole interface itself instead of sourcing the
# shared file. A backend that is missing one verb would fail deep inside a
# create/upgrade, so the interface is asserted verb by verb here.
for symbol in eng_version eng_container_exists eng_container_running eng_container_status \
  eng_container_image eng_labeled_containers eng_volume_exists eng_image_exists eng_image_id \
  eng_image_created eng_host_port eng_pull eng_image_remove eng_image_run \
  eng_create_persistent eng_create_ephemeral eng_start eng_stop eng_remove \
  eng_volume_create eng_volume_remove eng_exec eng_exec_test eng_exec_capture \
  eng_exec_background eng_logs eng_commit engine_mount_suffix; do
  if grep -qE "^${symbol}\(\)[[:space:]]*\{" installer/lib/backend-incus.sh; then
    pass "installer/lib/backend-incus.sh defines ${symbol}"
  else
    fail "installer/lib/backend-incus.sh does not define ${symbol}"
  fi
done
# install.sh is the single supported entry point; the bootc disk images and the
# host-side lifecycle helpers were removed with the container-only redesign.
for gone in disk_config .github/workflows/build-disk.yml scripts/switch.sh \
  scripts/rollback.sh scripts/doctor.sh runtime/lib/cmd-lifecycle.sh; do
  if [[ -e "$gone" ]]; then
    fail "${gone} should have been removed by the container-only redesign"
  else
    pass "${gone} is gone"
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

echo "ci coverage"
# README.md promises that every pull request runs every test script, so assert
# it here: a script CI silently stops running has to fail the lint instead of
# quietly drifting away from the documentation. Adding a test means adding it to
# this list *and* to build.yml, in the same change.
for script in tests/lint.sh tests/install.sh tests/smoke.sh tests/integration.sh tests/decoupling.sh tests/portability.sh tests/contract.sh tests/firstboot.sh tests/bootstrap.sh tests/i18n.sh tests/incus.sh; do
  if grep -qF -- "$script" .github/workflows/build.yml; then
    pass "build.yml runs ${script}"
  else
    fail "build.yml does not run ${script}"
  fi
done

echo "bootstrap stamp"
# install.sh is fetched on its own by `curl | bash`, so it carries the digests of
# the files it downloads. Editing installer/lib/* or image.env without re-stamping
# would ship a script that rejects its own files - and the failure would only be
# visible to a user running the documented install command, never in our tests.
if command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1; then
  if bash scripts/stamp-install.sh --check >/dev/null 2>&1; then
    pass "install.sh bootstrap checksums match the tree"
  else
    fail "install.sh bootstrap checksums are stale (run: just stamp)"
  fi
else
  pass "skipped install.sh bootstrap stamp (no sha256sum or shasum)"
fi

echo "test hygiene"
# `install.sh create` records the container under $DATA_HOME and skips a name
# that already has state there -- reporting success while creating nothing. The
# integration test therefore has to remove that state, not just the container:
# when it did not, every second run failed with a green `install.sh create`
# followed by "the created container is missing, not running".
integration_test=tests/integration.sh
if grep -qF 'agent-workspace/containers/${NAME}' "${integration_test}"; then
  pass "integration cleanup removes the installer state directory"
else
  fail "integration cleanup leaves \$DATA_HOME state behind, so the next run skips create"
fi
# The test takes the engine as configuration, so it must not reach past it to a
# hardcoded binary: that would make --engine=... decorative.
engine_calls="$(grep -nE '(^|[^/[:alnum:]_-])podman ' "${integration_test}" \
  | grep -vE '^[0-9]+:[[:space:]]*#' \
  | grep -vE 'ENGINE=' || true)"
if [[ -z "${engine_calls}" ]]; then
  pass "integration test drives the configured engine"
else
  fail "integration test calls podman directly instead of \"\${ENGINE}\": ${engine_calls}"
fi

echo "image labels"
# CI publishes the image, the Justfile builds it locally, and both are supposed
# to describe the same picture. When they drifted, the published image lost the
# Artifact Hub logo and called a commit sha its "version". Comparing the label
# keys both paths pass keeps that honest without pinning their values.
label_keys() {
  grep -oE -- '--label "[^"]+=' "$1" | sed 's/--label "//; s/=$//' | sort -u || true
}
justfile_labels="$(label_keys Justfile)"
ci_labels="$(label_keys .github/workflows/build.yml)"
if [[ -n "$justfile_labels" && "$justfile_labels" == "$ci_labels" ]]; then
  pass "Justfile and build.yml pass the same image labels"
else
  fail "image labels differ between Justfile and build.yml"
  diff <(printf '%s\n' "$justfile_labels") <(printf '%s\n' "$ci_labels") || true
fi
if grep -qE -- '--label "org\.opencontainers\.image\.version=\$\{\{ steps\.meta\.outputs\.git_sha' .github/workflows/build.yml; then
  fail "build.yml labels the image version with a git sha (revision is the sha)"
else
  pass "build.yml labels the image version with the tag, not a git sha"
fi

echo "ostree layout"
# Every ostree symlink the image writes through has to be materialised by
# 00-preflight and checked by build.sh. A dangling /opt broke pipx on every
# build; a dangling /home is worse, because the engine has to create the agent
# home mount point at container start and fails the whole create with
# `crun: creating '/home/agent': openat2 'home': No such file or directory`.
preflight_dirs="$(sed -n 's/.*for dir_mode in \(.*\); do.*/\1/p' build_files/modules/00-preflight/install.sh | head -1)"
verify_dirs="$(sed -n '/^verify_layout()/,/^}/p' build_files/build.sh | sed -n 's/.*for dir in \(.*\); do.*/\1/p' | head -1)"
for dir in /home /opt /usr/local /root; do
  case " ${preflight_dirs} " in
    *"\"${dir}:"*) pass "00-preflight materialises ${dir}";;
    *) fail "00-preflight does not materialise ${dir}";;
  esac
  case " ${verify_dirs} " in
    *" ${dir} "*) pass "verify_layout checks ${dir}";;
    *) fail "verify_layout does not check ${dir}";;
  esac
done
# The image has to name systemd as its own command: podman's --systemd=always
# does not replace one, so an image without this runs the inherited bash and
# exits instead of booting.
if grep -qE '^CMD \["/sbin/init"\]$' Containerfile; then
  pass 'Containerfile sets CMD ["/sbin/init"]'
else
  fail 'Containerfile does not set CMD ["/sbin/init"]'
fi

echo "author identity"
# The repository canonicalises the address spelling of its own account. History
# is deliberately not rewritten for it (the published image tags embed commit
# hashes), so .mailmap is the whole of the fix and this is what must keep
# holding. check-mailmap works on any checkout depth, unlike git shortlog.
# The other early author is a different person: folding him in would hide his
# commits from `git log --author=ian`, so the map must leave him alone.
canonical='Wraindrock <Wraindrock@users.noreply.github.com>'
separate='Ian <ian@users.noreply.github.com>'
if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
  mapped="$(git check-mailmap '<wraindrock@users.noreply.github.com>' 2>/dev/null || true)"
  if [[ "$mapped" == "$canonical" ]]; then
    pass ".mailmap folds <wraindrock@users.noreply.github.com> into the canonical author"
  else
    fail ".mailmap leaves <wraindrock@users.noreply.github.com> as [${mapped:-nothing}]"
  fi
  mapped="$(git check-mailmap "$separate" 2>/dev/null || true)"
  if [[ "$mapped" == "$separate" ]]; then
    pass ".mailmap keeps ${separate} as a separate author"
  else
    fail ".mailmap folds ${separate} into [${mapped:-nothing}]"
  fi
else
  pass "not a git checkout, skipped the author identity check"
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
