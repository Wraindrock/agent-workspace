#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Contract test: the declarative surface the project promises to keep stable.
#
# CHANGELOG.md:5-9 says the project follows Semantic Versioning "for the
# *declarative surface* - config/*.conf, image.env, install.sh, and the
# agent-workspace CLI". That promise was documentation only: nothing failed when
# someone renamed a subcommand, dropped a create flag, retyped an image.env key
# or added a CLI verb. This script turns each of those into an assertion, so an
# incompatible change to the surface has to be a deliberate edit *here* (a major
# version bump) instead of a silent rename.
#
# What it freezes:
#
#   install.sh (the host entry point)
#     - the subcommands dispatch actually routes (install.sh:521-547), the ls/rm
#       aliases, and the once-per-line aliases its own --help advertises, plus
#       that the hand-written help lists every one of them: the usage text is
#       the documented surface, and a subcommand no one can discover is not one.
#     - the flags the help advertises, and the create options it documents.
#     - exit codes: --help / -h / --version exit 0; an unknown subcommand and an
#       unknown flag exit non-zero with the right message. A stub engine is put
#       on PATH so these stay assertions about the parser and not about whether
#       this host has podman.
#
#   config/*.conf (agents and modules)
#     - every selector is still listed and still 0/1.
#     - the name-keyed contracts behind both files: an agent key must be a
#       recipe that declares AGENT_BINARIES/AGENT_TITLE/AGENT_ENV and
#       install_agent(), and a module key must be a directory whose MODULE_NAME
#       matches. Their consumers (40-agent-harnesses, build_files/build.sh:58)
#       key on exactly these names.
#     - the catalogue `install.sh --help-agents` prints is exactly the enabled
#       half of config/agents.conf, seen from the other side.
#
#   installer/lib/state.sh (snapshot ids)
#     - the id every new snapshot takes sorts strictly after every id that already
#       exists, with the clock frozen at each edge: a deleted id is free again, and
#       a clock that stepped backwards. An id that merely happens to be unused let
#       `--keep N` prune the snapshot it had just taken.
#
#   image.env and the agent-workspace CLI
#     - the keys install.sh reads are asserted by behaviour, on a mutated copy
#       of image.env: rename IMAGE_NAME and `install.sh --version` must print the
#       new name; truncate the file and it must print the documented default
#       (install.sh:207-216). Keys with no reader in the tree are presence-only.
#
#   runtime/bin/agent-workspace (the in-image CLI)
#     - its subcommands and exit codes. It is a host script that sources
#       /usr/lib/agent-workspace at runtime, so this neither runs it as shipped
#       nor greps it: the shared dispatcher is sourced with AGENT_WORKSPACE_LIB
#       pointed at runtime/lib, and the assertions are about the behaviour that
#       produces.
#
# No engine, no root and no network: everything is read, or executed against
# fakes inside a temporary copy of the tree. Each assertion counts, and the last
# line reports how many ran.
# ---------------------------------------------------------------------------
set -euo pipefail

cd "$(dirname "$0")/.."

ROOT="$(pwd)"
INSTALL_SH="${ROOT}/install.sh"
AW_CLI="${ROOT}/runtime/bin/agent-workspace"
AW_LIB="${ROOT}/runtime/lib"

failures=0
assertions=0
pass() { printf '  ok   %s\n' "$1"; assertions=$((assertions + 1)); }
fail() { printf '  fail %s\n' "$1"; assertions=$((assertions + 1)); failures=$((failures + 1)); }
info() { printf '  info %s\n' "$1"; }

# The help text is localised, and one of its assertions below quotes the English
# title ("agent-workspace installer"). Pin the language so the contract is the same
# on a zh_CN desktop as on a C locale; tests/i18n.sh asserts the Chinese block and
# the part of the surface that must not differ between languages.
export AW_LANG_OVERRIDE=en

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# A stub engine, so nothing below depends on what this host has installed. Most
# exercised paths die before an engine call; the image.env probe below is the one
# that gets as far as a dry-run, and for that the stub has to answer the queries
# install.sh makes before it prints the command line: `--version` (engine
# detection), and the existence/listing checks, which must all come back empty
# so the probe takes the "create it" path rather than the "already exists" one.
FAKE_BIN="${WORK}/fakebin"
mkdir -p "${FAKE_BIN}"
cat >"${FAKE_BIN}/podman" <<'STUB'
#!/bin/sh
# eng_container_exists() is `container inspect NAME` and reads its exit status
# (installer/lib/engine.sh:66), so "nothing exists" means inspect must *fail*.
case "$1" in
  --version) echo "podman version 0.0.0-contract-stub" ;;
  container)
    case "$2" in
      inspect) exit 1 ;;
      *) exit 0 ;;
    esac ;;
  *) exit 0 ;;
esac
STUB
chmod 0755 "${FAKE_BIN}/podman"

run_installer() { # run_installer [args...] -> sets RUN_STATUS / RUN_OUT
  RUN_STATUS=0
  RUN_OUT="$(env PATH="${FAKE_BIN}:${PATH}" bash "${INSTALL_SH}" "$@" 2>&1 </dev/null)" || RUN_STATUS=$?
}

# --- 1. the help text, captured once ---------------------------------------
echo "install.sh help"
HELP="${WORK}/help.out"
run_installer --help
if [[ "${RUN_STATUS}" -eq 0 ]]; then
  pass "install.sh --help exits 0"
else
  fail "install.sh --help exits ${RUN_STATUS}, want 0"
fi
if [[ "${RUN_OUT}" == *"agent-workspace installer"* ]]; then
  pass "install.sh --help prints its usage"
else
  fail "install.sh --help printed [${RUN_OUT:-nothing}]"
fi
printf '%s\n' "${RUN_OUT}" >"${HELP}"

# The documented surface: a usage entry that opens a line, so `list` is not
# satisfied by "list the containers" in the prose. The `|` of the one combined
# entry (`./install.sh start|stop|restart NAME`) is normalised to a space first,
# so each of those three is asserted on its own.
normalised_help="${WORK}/help.normalised"
sed 's/|/ /g' "${HELP}" >"${normalised_help}"
help_has_subcommand() { # help_has_subcommand NAME
  # The name opens the entry, or follows a normalised separator within it, so
  # the one combined entry documents all three of its verbs.
  grep -qE "(^| )${1}( |$)" "${normalised_help}" \
    && grep -qE "^  \./install\.sh .*${1}" "${normalised_help}"
}
# help_has_flag FLAG -- the flag opens a help entry, followed by one of the
# separators the writer uses (`--help, -h`, `--engine auto`, `--dry-run, -n`).
# Requiring the whole token keeps `--help` from matching `--help-agents`. A flag
# may also be documented mid-entry rather than at the start (the `logs` line
# carries `--follow, -f / --tail N`), and there the leading context must end on a
# separator, so `--tail` is not satisfied by `--digestfile`.
help_has_flag() { # help_has_flag FLAG
  grep -qE "^  ${1}([,[:space:]].*)?$" "${HELP}" \
    || grep -qE "(^|[,[:space:]/])${1}([,[:space:]].*)?$" "${HELP}"
}

# --- 2. install.sh subcommands ---------------------------------------------
echo "install.sh subcommands"

# Every subcommand dispatch routes (install.sh:521-547). The rules are read out
# of the file rather than listed here so that a *new* subcommand is covered for
# free; the ones this test additionally freezes are named below, because they
# are the surface and must not quietly disappear from dispatch.
#
# The rule's pattern list has to end the case arm (`create)` or `list|ls)`) --
# anchored, so helper `case` statements elsewhere are not mistaken for
# subcommands. The test is on the *first field*, because a rule line carries the
# handler after the closing paren (`create) do_create ;;`); `[)]` and `[|]` are
# spelled as bracket expressions because in ERE `\)` closes a group and a bare
# `|` inside a group is alternation.
frozen_subcommands="create fork"
subcommands=()
while IFS= read -r name; do subcommands+=("${name}"); done < <(
  awk '$1 ~ /^[a-z][a-z-]*([|][a-z][a-z-]*)*[)]$/ {
         line = $1
         sub(/[)]$/, "", line)
         n = split(line, parts, "|")
         for (i = 1; i <= n; i++) print parts[i]
       }' "${INSTALL_SH}" | sort -u
)
if [[ "${#subcommands[@]}" -gt 0 ]]; then
  pass "install.sh dispatch is intact (${#subcommands[@]} subcommands)"
  for name in "${subcommands[@]}"; do
    pass "install.sh routes ${name}"
  done
else
  fail "install.sh has no dispatch rules at all (install.sh:521-547)"
fi
for name in ${frozen_subcommands}; do
  if printf '%s\n' "${subcommands[@]}" | grep -qx "${name}"; then
    pass "install.sh still routes ${name} (frozen)"
  else
    fail "install.sh no longer routes ${name}"
  fi
done

# The aliases dispatch also accepts. An alias is part of the surface: someone's
# script says `install.sh ls`.
for alias in ls rm; do
  if printf '%s\n' "${subcommands[@]}" | grep -qx "${alias}"; then
    pass "install.sh accepts the ${alias} alias"
  else
    fail "install.sh no longer accepts the ${alias} alias"
  fi
done

# The subcommands whose --help entry is a line of its own: the documented
# surface, asserted entry by entry.
for name in create list enter shell web logs start stop restart \
  snapshot snapshots rollback recover fork upgrade remove doctor root; do
  if help_has_subcommand "${name}"; then
    pass "install.sh --help documents ${name}"
  else
    fail "install.sh --help no longer documents the ${name} subcommand"
  fi
done

# --- 3. install.sh flags and create options --------------------------------
echo "install.sh flags"
for flag in --agent --name --count --mode --workspace --env --file --save \
  --web-port --no-web --engine --image --no-tui --dry-run --no-pull --yes \
  --quiet --strict --keep --purge-snapshots --keep-volume --skip-safety \
  --follow --tail --help-agents --help; do
  if help_has_flag "${flag}"; then
    pass "install.sh --help documents ${flag}"
  else
    fail "install.sh --help no longer documents ${flag}"
  fi
done

# create's own options, asserted as such rather than only as help text: each one
# appears on a create-options line in the usage block.
for flag in --agent --name --count --mode --workspace --no-web --yes; do
  if help_has_flag "${flag}"; then
    pass "create documents ${flag}"
  else
    fail "create no longer documents ${flag}"
  fi
done

# --- 4. install.sh exit codes ----------------------------------------------
echo "install.sh exit codes"

run_installer --help
[[ "${RUN_STATUS}" -eq 0 ]] && pass "install.sh --help exits 0" \
  || fail "install.sh --help exits ${RUN_STATUS}, want 0"
run_installer -h
[[ "${RUN_STATUS}" -eq 0 ]] && pass "install.sh -h exits 0" \
  || fail "install.sh -h exits ${RUN_STATUS}, want 0"

run_installer --version
[[ "${RUN_STATUS}" -eq 0 ]] && pass "install.sh --version exits 0" \
  || fail "install.sh --version exits ${RUN_STATUS}, want 0"
[[ "${RUN_OUT}" == *"agent-workspace"* ]] \
  && pass "install.sh --version names the project" \
  || fail "install.sh --version printed [${RUN_OUT:-nothing}]"

# An unknown subcommand is a usage error. Without the stub engine the installer
# would die on "neither podman nor docker is installed" instead, which would
# satisfy a bare non-zero check for the wrong reason.
run_installer frobnicate
[[ "${RUN_STATUS}" -ne 0 ]] && pass "an unknown subcommand fails (exit ${RUN_STATUS})" \
  || fail "an unknown subcommand exited 0"
[[ "${RUN_OUT}" == *"unknown command"* ]] \
  && pass "the unknown subcommand names itself" \
  || fail "the unknown subcommand message is [${RUN_OUT:-nothing}], want 'unknown command'"

run_installer --frobnicate
[[ "${RUN_STATUS}" -ne 0 ]] && pass "an unknown flag fails (exit ${RUN_STATUS})" \
  || fail "an unknown flag exited 0"
[[ "${RUN_OUT}" == *"unknown option"* ]] \
  && pass "the unknown flag names itself" \
  || fail "the unknown flag message is [${RUN_OUT:-nothing}], want 'unknown option'"

# Every dispatch rule that calls a cmd_* handler is paired with a definition in
# installer/lib/commands.sh; a subcommand that loses its handler is caught here
# as well as by the exit-code cases above.
handlers="$(sed -n 's/^    [a-z][a-z-]*).*\(cmd_[a-z_]*\).*/\1/p' "${INSTALL_SH}" | sort -u)"
if [[ -n "${handlers}" ]]; then
  for handler in ${handlers}; do
    if grep -qE "^${handler}\(\) \{" installer/lib/commands.sh; then
      pass "installer/lib/commands.sh defines ${handler}"
    else
      fail "installer/lib/commands.sh does not define ${handler}"
    fi
  done
else
  fail "install.sh dispatch names no handlers at all (install.sh:521-547)"
fi

# --- 5. config/*.conf -------------------------------------------------------
echo "config/*.conf"

conf_keys() { # conf_keys FILE -- the selectors, comments stripped
  sed 's/#.*//' "$1" | sed -n 's/^\([A-Za-z0-9_-]*\)=.*/\1/p'
}
conf_value() { # conf_value FILE KEY
  sed 's/#.*//' "$1" | sed -n "s/^${2}=\(.*\)\$/\1/p" | head -1
}

agent_keys="$(conf_keys config/agents.conf)"
module_keys="$(conf_keys config/modules.conf)"

for name in dsh opencode claude-code codex gemini-cli aider; do
  if printf '%s\n' "${agent_keys}" | grep -qx "${name}"; then
    pass "config/agents.conf still selects ${name}"
  else
    fail "config/agents.conf no longer selects ${name}"
  fi
done

for name in 00-preflight 10-base-packages 20-container-tools 30-agent-toolchains \
  40-agent-harnesses 45-dsh-plugins 50-devtools 60-system-config 80-manifest 90-cleanup; do
  if printf '%s\n' "${module_keys}" | grep -qx "${name}"; then
    pass "config/modules.conf still selects ${name}"
  else
    fail "config/modules.conf no longer selects ${name}"
  fi
done

# Both files are parsed as `key=0|1`; anything else is a different
# mini-language, not a rename.
bad_values=""
for value in $(sed 's/#.*//' config/agents.conf | sed -n 's/^[A-Za-z0-9_-]*=\(.*\)$/\1/p') \
             $(sed 's/#.*//' config/modules.conf | sed -n 's/^[A-Za-z0-9_-]*=\(.*\)$/\1/p'); do
  case "${value}" in
    0|1) ;;
    *) bad_values="${bad_values} [${value}]" ;;
  esac
done
if [[ -z "${bad_values}" ]]; then
  pass "every selector in config/agents.conf and config/modules.conf is 0 or 1"
else
  fail "config/*.conf has non-boolean selectors:${bad_values}"
fi

# The two files do not merely look similar: their consumers key on the names.
# build_files/modules/40-agent-harnesses/install.sh:7 reads config/agents.conf
# and maps each key to <recipe>.sh; a recipe without AGENT_BINARIES/AGENT_TITLE/
# AGENT_ENV installs an agent the installer menu cannot describe.
for name in ${agent_keys}; do
  recipe="build_files/modules/40-agent-harnesses/agents/${name}.sh"
  if [[ ! -f "${recipe}" ]]; then
    fail "config/agents.conf names ${name}, but ${recipe} does not exist"
    continue
  fi
  missing=""
  grep -qE '^AGENT_BINARIES="[^"]+"$' "${recipe}" || missing="${missing} AGENT_BINARIES"
  grep -qE '^AGENT_TITLE="[^"]+"$' "${recipe}" || missing="${missing} AGENT_TITLE"
  grep -qE '^AGENT_ENV="[^"]+"$' "${recipe}" || missing="${missing} AGENT_ENV"
  if [[ -z "${missing}" ]]; then
    pass "agent recipe ${name} declares AGENT_BINARIES, AGENT_TITLE and AGENT_ENV"
  else
    fail "agent recipe ${name} is missing${missing}"
  fi
  grep -qE '^install_agent\(\) \{' "${recipe}" \
    && pass "agent recipe ${name} defines install_agent()" \
    || fail "agent recipe ${name} does not define install_agent()"
done

# How an agent is *started* is a contract too, and one that no source-level check
# used to cover. `ephemeral` runs `run <image> <agent command>` and disposes of the
# container when it exits, so an agent whose command cannot start turns ephemeral
# mode into "create a container that dies instantly". dsh was exactly that: its
# binary invoked bare exits 1 with `error: --profile <name> is required`, and the
# installer handed the container nothing but the binary name.
#
# These assertions are source-level on purpose - they must run with no engine, no
# image and no network. They pin the two things that were wrong:
#   1. launch is resolved through agent_launch_command, not agent_binary_of, at
#      every call site that starts an agent;
#   2. the `dsh` entry names a profile the *image* ships, not one that merely
#      exists on somebody's $DSH_HOME. The package README lists the profiles that
#      self-initialise: web, headless, sdk, sdk-minimal, acp.
agents_lib="installer/lib/agents.sh"
if grep -qE '^agent_launch_command\(\) \{' "${agents_lib}"; then
  pass "the agent catalogue resolves a launch command, not just a binary"
else
  fail "installer/lib/agents.sh has no agent_launch_command()"
fi

dsh_launch="$(bash -c 'source installer/lib/agents.sh; builtin_agents; agent_launch_command dsh')"
dsh_binary="$(bash -c 'source installer/lib/agents.sh; builtin_agents; agent_binary_of dsh')"
if [[ "${dsh_launch}" == *"--profile"* ]]; then
  pass "dsh is launched with a profile (${dsh_launch})"
else
  fail "dsh is launched bare (${dsh_launch:-<empty>}); dsh exits 1 with '--profile <name> is required'"
fi

dsh_profile="${dsh_launch##*--profile }"
dsh_profile="${dsh_profile%% *}"
# The shipped profiles, space-padded so a membership test cannot match `sdk` inside
# `sdk-minimal`. Kept in a variable rather than inline so shellcheck does not read
# the word as a constant (SC2194).
shipped_dsh_profiles=" web headless sdk sdk-minimal acp "
if [[ "${shipped_dsh_profiles}" == *" ${dsh_profile} "* ]]; then
  pass "the dsh profile ${dsh_profile} is one the image ships"
else
  fail "the dsh profile '${dsh_profile}' is not a shipped profile (web, headless, sdk, sdk-minimal, acp); a profile only present on the host's \$DSH_HOME fails with 'profile does not exist'"
fi

# ephemeral promises "answer one task and exit": a profile that does not return
# would hold the container open forever and defeat the mode.
if [[ "${dsh_profile}" == "headless" ]]; then
  pass "ephemeral launches the dsh profile that answers one task and exits"
else
  fail "ephemeral launches the '${dsh_profile}' profile, which does not answer one task and exit"
fi

if [[ "${dsh_launch}" != "${dsh_binary}" ]]; then
  pass "launching dsh differs from naming its binary, so the two are not interchangeable"
else
  fail "agent_launch_command dsh returns the bare binary"
fi

# Every call site that starts an agent has to go through the resolver; one that
# still builds the command from the binary name reintroduces the bug for that path.
for site in installer/lib/commands.sh install.sh; do
  [[ -f "${site}" ]] || continue
  start_sites="$(grep -nE 'eng_exec [^|;]*agent_binary_of|eargs\+=.*agent_binary_of' "${site}" || true)"
  if [[ -z "${start_sites}" ]]; then
    pass "${site} starts agents through agent_launch_command"
  else
    fail "${site} builds an agent command from agent_binary_of: ${start_sites}"
  fi
done

# opencode has no profile grammar, so the resolver must still return its binary.
opencode_launch="$(bash -c 'source installer/lib/agents.sh; builtin_agents; agent_launch_command opencode')"
if [[ "${opencode_launch}" == "opencode" ]]; then
  pass "an agent with no profile grammar is launched by its binary (opencode)"
else
  fail "opencode launch command changed unexpectedly: ${opencode_launch:-<empty>}"
fi

# and then to its MODULE_NAME, so that name is load-bearing too.
for name in ${module_keys}; do
  module_env="build_files/modules/${name}/module.env"
  if [[ ! -f "${module_env}" ]]; then
    fail "config/modules.conf names ${name}, but ${module_env} does not exist"
    continue
  fi
  grep -qE "^MODULE_NAME=\"?${name}\"?$" "${module_env}" \
    && pass "module ${name} declares MODULE_NAME=${name}" \
    || fail "module ${name} declares a different MODULE_NAME"
done

# The host installer's menu and config/agents.conf are the same list seen from
# two sides: the recipes with `=1` are exactly the agents `--help-agents`
# offers. A recipe nobody enables is not part of the surface and must not show
# up on the host; an enabled one that goes missing must.
menu_status=0
menu="$(env PATH="${FAKE_BIN}:${PATH}" bash "${INSTALL_SH}" --help-agents 2>&1 </dev/null)" || menu_status=$?
[[ "${menu_status}" -eq 0 ]] && pass "install.sh --help-agents exits 0" \
  || fail "install.sh --help-agents exits ${menu_status}, want 0"
menu_names="$(printf '%s\n' "${menu}" | awk 'NF { print $1 }' | sort -u)"
enabled_agents=""
for name in ${agent_keys}; do
  [[ "$(conf_value config/agents.conf "${name}")" == "1" ]] && enabled_agents="${enabled_agents}${name}"$'\n'
done
enabled_agents="$(printf '%s' "${enabled_agents}" | sed '/^$/d' | sort -u)"
if [[ -n "${menu_names}" && "${menu_names}" == "${enabled_agents}" ]]; then
  pass "install.sh offers exactly the agents config/agents.conf enables ($(printf '%s' "${enabled_agents}" | tr '\n' ' '))"
else
  fail "install.sh offers [$(printf '%s' "${menu_names}" | tr '\n' ' ')], config/agents.conf enables [$(printf '%s' "${enabled_agents}" | tr '\n' ' ')]"
fi

# --- 6. snapshot ids --------------------------------------------------------
echo "snapshot ids"

# Snapshot ids are second-granular and compared as strings, so the id a new
# snapshot takes has to sort strictly after every id that exists - not merely be
# unused. Deleting a snapshot frees its id, and a freed id can sit *below* one
# that is still taken (`...Zb` free while `...Zbb` exists); taking it made
# `--keep N` prune the snapshot it had just committed, and made `latest` and
# `recover` resolve to an older one. The clock is frozen inside these probes by
# defining a `date` function, so the collision is reproduced on demand instead of
# being hoped for - on a real clock it needs two snapshots inside one second.
snapshot_next_id_case() { # snapshot_next_id_case FROZEN_ID EXISTING_ID...
  local frozen="$1" existing home
  shift
  home="$(mktemp -d)"
  for existing in "$@"; do
    mkdir -p "${home}/snapshots/demo/${existing}"
    : >"${home}/snapshots/demo/${existing}/meta"
  done
  DATA_HOME="${home}" SNAPSHOT_FROZEN_ID="${frozen}" bash -c '
    source installer/lib/state.sh
    date() { printf "%s\n" "${SNAPSHOT_FROZEN_ID}"; }
    snapshot_next_id demo
  '
  rm -rf "${home}"
}

if grep -qE '^snapshot_next_id\(\) \{' installer/lib/state.sh; then
  pass "installer/lib/state.sh derives a snapshot id through snapshot_next_id()"
else
  fail "installer/lib/state.sh has no snapshot_next_id()"
fi

got="$(snapshot_next_id_case 20261016T000000Z 20261016T000000Zbb)"
if [[ "${got}" > 20261016T000000Zbb ]]; then
  pass "a snapshot taken while a lower id is free sorts after the newest one (${got})"
else
  fail "snapshot_next_id handed out ${got:-<empty>} beside the existing 20261016T000000Zbb, so --keep N would prune the snapshot it had just taken"
fi

# a clock that steps backwards must not produce an id that sorts older either
got="$(snapshot_next_id_case 20261016T000000Z 20261016T000100Z)"
if [[ "${got}" > 20261016T000100Z ]]; then
  pass "a snapshot taken after the clock steps back still sorts newest (${got})"
else
  fail "snapshot_next_id handed out ${got:-<empty>} after the clock stepped back from 20261016T000100Z"
fi

# and cmd_snapshot takes its id from there rather than stamping the clock itself
if grep -qE 'id="\$\(snapshot_next_id' installer/lib/commands.sh &&
  ! grep -qE '%Y%m%dT%H%M%SZ' installer/lib/commands.sh; then
  pass "cmd_snapshot takes its id from snapshot_next_id(), not from the clock"
else
  fail "cmd_snapshot still stamps its own snapshot id"
fi

# --- 7. image.env -----------------------------------------------------------
echo "image.env"

# The keys install.sh reads are asserted by behaviour, not by presence: a copy
# of image.env with IMAGE_NAME renamed has to stop producing that image name,
# and a truncated one has to fall back to the defaults install.sh:207-216
# documents. That covers a whole class of rename -- a key that has a reader --
# and it needs no engine.
#
# install.sh resolves the image through default_image(), which reads
# image.env:207-216, but two paths never reach it: `--version` prints
# "${IMAGE:-default}" straight out of parse_args (install.sh:612), before main()
# resolves anything, and `--help` returns even earlier. `create --dry-run` does
# reach it, and --dry-run is the one mode that runs with no engine present, so
# the probe drives that and reads the resulting engine command line.
#
# install.sh sources its libraries through the directory it lives in
# (install.sh:21-31), so the probe is a temporary copy of install.sh, its
# libraries and image.env -- not the whole tree.
make_imageenv_probe() { # make_imageenv_probe DIR IMAGE_ENV_CONTENT_FILE
  mkdir -p "${1}/installer"
  cp "${INSTALL_SH}" "${1}/install.sh"
  cp -R installer/lib "${1}/installer/lib"
  cp "${2}" "${1}/image.env"
}
imageenv_image() { # imageenv_image DIR -> the image a dry-run create would use
  # A name unique to this run: install.sh skips a create whose name already
  # exists outside it, and that short-circuit never reaches the image. The name
  # is also what keeps the probe from colliding with a real container on a
  # developer's host. --name is given explicitly, so the probe never resolves a
  # workspace path either.
  env PATH="${FAKE_BIN}:${PATH}" bash "${1}/install.sh" \
    create --agent dsh --name "aw-contract-probe-$$" --yes --dry-run 2>&1 </dev/null
}

probe_env="${WORK}/probe.env"
sed 's/^IMAGE_NAME=.*/IMAGE_NAME="probe-image"/' image.env >"${probe_env}"

probe_repo="${WORK}/imageenv-probe"
make_imageenv_probe "${probe_repo}" "${probe_env}"
probe_status=0
probe_out="$(imageenv_image "${probe_repo}")" || probe_status=$?
[[ "${probe_status}" -eq 0 ]] && pass "install.sh --dry-run still runs against a copy of image.env" \
  || fail "install.sh --dry-run exited ${probe_status} against a copy of image.env"
if [[ "${probe_out}" == *"probe-image"* ]]; then
  pass "install.sh reads IMAGE_NAME from image.env"
else
  fail "install.sh ignored IMAGE_NAME (the engine command line was [${probe_out:-nothing}])"
fi

# The same copy with the key renamed instead of revalued: default_image() then
# falls through to its "agent-workspace" default, so the probe image must
# disappear from the command line.
renamed_repo="${WORK}/imageenv-renamed"
make_imageenv_probe "${renamed_repo}" /dev/null
sed 's/^IMAGE_NAME=.*/PROBE_RENAMED_NAME="probe-image"/' image.env >"${renamed_repo}/image.env"
renamed_out="$(imageenv_image "${renamed_repo}" || true)"
if [[ "${renamed_out}" != *"probe-image"* ]]; then
  pass "renaming the IMAGE_NAME key removes it from the surface"
else
  fail "install.sh still found the image name after the IMAGE_NAME key was renamed"
fi

# ... and with the file emptied, the documented defaults take over.
: >"${renamed_repo}/image.env"
truncated_out="$(imageenv_image "${renamed_repo}" || true)"
if [[ "${truncated_out}" == *"agent-workspace"* ]]; then
  pass "an empty image.env falls back to the documented default image name"
else
  fail "an empty image.env produced [${truncated_out:-nothing}], want the default agent-workspace"
fi

# The keys with no reader in the tree (IMAGE_KEYWORDS, IMAGE_LOGO_URL) are
# consumed by the Justfile (dotenv) and .github/workflows/build.yml at workflow
# start, so deleting one breaks them before any test could run. Presence is what
# this script can assert; the build itself is the behavioural check.
for key in IMAGE_NAME REPO_ORGANIZATION IMAGE_DESC IMAGE_KEYWORDS IMAGE_LOGO_URL \
  IMAGE_LICENSE DEFAULT_TAG BASE_IMAGE AGENT_USER; do
  grep -qE "^${key}=" image.env \
    && pass "image.env defines ${key}" \
    || fail "image.env no longer defines ${key}"
done

# --- 8. the agent-workspace CLI ---------------------------------------------
echo "runtime/bin/agent-workspace"

# The CLI is not a host script: it sources /usr/lib/agent-workspace
# (runtime/bin/agent-workspace:14 redirects AGENT_WORKSPACE_LIB there, and the
# image populates that directory from runtime/lib). Pointing the variable at the
# tree is what makes it runnable here, and behaviour is what gets asserted: a
# rename that leaves dispatch, help and exit codes intact would be invisible to
# a grep anyway.
aw() { ( AGENT_WORKSPACE_LIB="${AW_LIB}" bash "${AW_CLI}" "$@" ) 2>&1; }
aw_status() { # aw_status [args...] -> sets AW_STATUS / AW_OUT
  AW_STATUS=0
  AW_OUT="$(aw "$@")" || AW_STATUS=$?
}

if [[ -f "${AW_LIB}/common.sh" ]]; then
  pass "runtime/lib/common.sh exists"
else
  fail "runtime/lib/common.sh is missing, so the CLI cannot even load"
fi

aw_status help
[[ "${AW_STATUS}" -eq 0 ]] && pass "agent-workspace help exits 0" \
  || fail "agent-workspace help exits ${AW_STATUS}, want 0"
aw_status --help
[[ "${AW_STATUS}" -eq 0 ]] && pass "agent-workspace --help exits 0" \
  || fail "agent-workspace --help exits ${AW_STATUS}, want 0"
aw_status -h
[[ "${AW_STATUS}" -eq 0 ]] && pass "agent-workspace -h exits 0" \
  || fail "agent-workspace -h exits ${AW_STATUS}, want 0"

# version and status are host-safe: they read the environment, not the image.
for command in version status; do
  aw_status "${command}"
  if [[ "${AW_STATUS}" -eq 0 ]]; then
    pass "agent-workspace ${command} exits 0"
  else
    fail "agent-workspace ${command} exits ${AW_STATUS}, want 0"
  fi
done
aw_status version
[[ "${AW_OUT}" == *"image"* ]] && pass "agent-workspace version prints an image line" \
  || fail "agent-workspace version printed [${AW_OUT:-nothing}]"
aw_status status
[[ "${AW_OUT}" == *"mode"* ]] && pass "agent-workspace status prints a mode line" \
  || fail "agent-workspace status printed [${AW_OUT:-nothing}]"
aw_status status --json
[[ "${AW_STATUS}" -eq 0 ]] && pass "agent-workspace status accepts --json" \
  || fail "agent-workspace status --json exits ${AW_STATUS}, want 0"

# manifest, modules and agents guard themselves against an absent image record
# and exit 1 through die(). The two guarded verbs are asserted on their exit
# code and on reaching their own handler: a rename that drops the verb from the
# dispatch would answer "unknown command" (exit 2) instead.
for command in manifest modules; do
  aw_status "${command}"
  if [[ "${AW_STATUS}" -eq 1 ]]; then
    pass "agent-workspace ${command} fails with exit 1 outside the image"
  else
    fail "agent-workspace ${command} exited ${AW_STATUS} outside the image, want 1"
  fi
  if [[ "${AW_OUT}" != *"unknown command"* ]]; then
    pass "agent-workspace ${command} reaches its own handler"
  else
    fail "agent-workspace ${command} fell through to the unknown-command branch"
  fi
done

# agents is the exception: outside an image it has nothing to report, says so
# and exits 0 (runtime/lib/cmd-info.sh:45-48). Both the verb and that behaviour
# are asserted, because it is the only one of the four that succeeds here.
aw_status agents
[[ "${AW_STATUS}" -eq 0 ]] && pass "agent-workspace agents exits 0 outside the image" \
  || fail "agent-workspace agents exited ${AW_STATUS} outside the image, want 0"
[[ "${AW_OUT}" != *"unknown command"* ]] \
  && pass "agent-workspace agents reaches its own handler" \
  || fail "agent-workspace agents fell through to the unknown-command branch"

# An unknown verb has to be reported as one, and to exit 2 rather than 1: a
# caller differentiating "not in this image" from "typo" relies on it.
aw_status frobnicate
[[ "${AW_STATUS}" -eq 2 ]] && pass "agent-workspace rejects an unknown verb with exit 2" \
  || fail "agent-workspace frobnicate exited ${AW_STATUS}, want 2"
[[ "${AW_OUT}" == *"unknown command: frobnicate"* ]] \
  && pass "agent-workspace names the unknown verb" \
  || fail "agent-workspace said [${AW_OUT:-nothing}], want 'unknown command: frobnicate'"

# doctor is the exception: outside a container it reports its findings instead of
# dying, so it is asserted as a known verb (anything but the unknown-command
# exit 2), not as a particular exit code.
aw_status doctor
if [[ "${AW_STATUS}" -ne 2 ]]; then
  pass "agent-workspace doctor is a known verb (exit ${AW_STATUS})"
else
  fail "agent-workspace doctor is treated as an unknown command"
fi
aw_status doctor --help
if [[ "${AW_STATUS}" -ne 2 ]]; then
  pass "agent-workspace doctor --help is accepted by the handler (exit ${AW_STATUS})"
else
  fail "agent-workspace doctor --help is treated as an unknown command"
fi

# --- 9. the prompt surface ---------------------------------------------------
echo "the prompt surface"

# Every call site takes a prompt's answer through a command substitution
# (`name="$(ui_input ...)"`, `value="$(ui_secret ...)"`), so whatever a prompt
# prints on *stdout* is read back as part of the value. With the prompt on stdout,
# ui_input returned "Name [dsh-box]: dsh-box" - a name that then fails validation -
# and ui_secret returned its own prompt with the key glued behind it, which is what
# would have been written to the 0600 credential file. Both prompts belong on
# stderr. The branch asserted here is the no-extra-terminal one (no gum, no
# UI_TTY_FD); the fd-backed branch writes to the terminal descriptor instead.
prompt_probe() { # prompt_probe FUNCTION HEADER INPUT
  bash -c '
    source installer/lib/i18n.sh
    source installer/lib/ui.sh
    NO_TUI=0 GUM_BIN="" UI_TTY_FD=""
    "$1" "$2" <<<"$3" 2>/dev/null
  ' _ "$1" "$2" "$3"
}

got="$(prompt_probe ui_input "Name [dsh-box]" "dsh-box" || true)"
if [[ "${got}" == "dsh-box" ]]; then
  pass "ui_input returns the answer alone, with its prompt on stderr"
else
  fail "ui_input returned [${got}]: its prompt is on stdout and the caller captures it"
fi

got="$(prompt_probe ui_secret "DEEPSEEK_API_KEY (enter to skip)" "sk-not-a-real-key" || true)"
if [[ "${got}" == "sk-not-a-real-key" ]]; then
  pass "ui_secret returns the secret alone, with its prompt on stderr"
else
  fail "ui_secret returned [${got}]: its prompt would be written into the credential file"
fi

echo
if [[ "${failures}" -eq 0 ]]; then
  printf 'contract: all checks passed (%d assertions)\n' "${assertions}"
else
  printf 'contract: %d of %d check(s) failed\n' "${failures}" "${assertions}"
  exit 1
fi
