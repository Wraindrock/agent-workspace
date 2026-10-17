#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Integration tests for the host installer (install.sh).
#
# podman and docker are faked (tests/fixtures/fake-engine.sh), so this runs
# anywhere: no root, no container engine, no network. It asserts the commands
# the installer runs against the engine, the state and credentials it writes on
# the host, the container lifecycle (create / enter / snapshot / rollback /
# recover / fork / upgrade / remove) and its exit codes.
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
FAKE="$ROOT/tests/fixtures/fake-engine.sh"
INSTALLER="$ROOT/install.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export HOME="$WORK/home"
export XDG_CONFIG_HOME="$WORK/config"
export XDG_DATA_HOME="$WORK/data"
export WORKSPACE_ROOT="$WORK/workspaces"
export FAKE_ENGINE_STATE="$WORK/fake-state"
export DEEPSEEK_API_KEY="sk-test-dsh-key"
# The installer speaks the language of the host locale, so pin it: the assertions
# below quote English sentences from --help and from the prompts, and inheriting a
# zh_CN desktop would fail them for no reason. tests/i18n.sh is where the other
# language is asserted.
export AW_LANG_OVERRIDE=en
# keep auto-assigned web ports out of the well-known range a real host may use
export WEB_PORT_BASE=34700

BIN="$WORK/bin"
BIN_DOCKER="$WORK/bin-docker"
# A PATH that offers the everyday tools but no container engine at all. The
# engine selection tests build on this instead of on /usr/bin, so they never
# pick up a real podman or docker just because the host (or a CI runner) has
# one installed.
BIN_NOSH="$WORK/bin-nosh"
# ${CONF_HOME}/agent-workspace/backend holds the remembered backend choice. The
# test that asserts "with no remembered choice the installer refuses" moves this
# aside on purpose, so keep the path in one place.
CONF_DIR="$XDG_CONFIG_HOME/agent-workspace"
mkdir -p "$BIN" "$BIN_DOCKER" "$BIN_NOSH" "$HOME" "$WORKSPACE_ROOT" "$FAKE_ENGINE_STATE" "$CONF_DIR"

# make_engine_wrapper DIR NAME: a podman/docker stand-in that delegates to the fake
make_engine_wrapper() {
  local dir="$1" name="$2"
  cat >"$dir/$name" <<WRAPPER
#!/usr/bin/env bash
FAKE_ENGINE_NAME=$name exec "$FAKE" "\$@"
WRAPPER
  chmod 0755 "$dir/$name"
}
make_engine_wrapper "$BIN" podman
make_engine_wrapper "$BIN" docker
# a PATH that only offers docker, for the engine selection tests
make_engine_wrapper "$BIN_DOCKER" docker

export PATH="$BIN:$PATH"

for tool in bash sh env cat sed grep tr head tail sort date dirname basename mkdir \
  rm cp mv chmod install tar find ls cut awk expr uname id sleep touch wc ln du df \
  mktemp uniq tee sha256sum realpath readlink stat hostname seq which paste; do
  tool_path="$(command -v "$tool" 2>/dev/null || true)"
  [[ -n "$tool_path" ]] && ln -sf "$tool_path" "$BIN_NOSH/$tool"
done

# a PATH that offers docker and nothing else, for the engine selection tests
DOCKER_ONLY_PATH="$BIN_DOCKER:$BIN_NOSH"

# A remembered backend choice, the same file `install.sh backend set` writes.
# There is no automatic selection any more, and `run` always feeds the installer
# /dev/null: without this every command below would refuse for want of a choice.
# The "no remembered choice" tests below move this file aside on purpose.
printf 'backend=podman\n' >"$CONF_DIR/backend"
chmod 0600 "$CONF_DIR/backend"

# A PATH whose `date` freezes the snapshot-id call, so two snapshots can be made
# inside the same "second" on demand - the condition under which ids used to be
# handed back out in the wrong order. Everything else falls through to the real
# date, and only the snapshot-id assertions below use this PATH.
REAL_DATE="$(command -v date)"
BIN_SAME_SECOND="$WORK/bin-same-second"
mkdir -p "$BIN_SAME_SECOND"
cat >"$BIN_SAME_SECOND/date" <<SHIM
#!/usr/bin/env bash
if [[ "\${1:-}" == "-u" && "\${2:-}" == "+%Y%m%dT%H%M%SZ" ]]; then
  printf '20261016T000000Z\n'
  exit 0
fi
exec "$REAL_DATE" "\$@"
SHIM
chmod 0755 "$BIN_SAME_SECOND/date"
SAME_SECOND_PATH="$BIN_SAME_SECOND:$PATH"

PASS=0
FAIL=0
pass() { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

is() { # is LABEL EXPECTED ACTUAL
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected [$2], got [$3])"; fi
}
contains() { # contains LABEL NEEDLE HAYSTACK
  case "$3" in
    *"$2"*) pass "$1" ;;
    *) fail "$1 (missing [$2] in output)" ;;
  esac
}
lacks() { # lacks LABEL NEEDLE HAYSTACK -- the needle must not appear
  case "$3" in
    *"$2"*) fail "$1 (unexpected [$2] in output)" ;;
    *) pass "$1" ;;
  esac
}
exists() { # exists LABEL PATH
  if [[ -e "$2" ]]; then pass "$1"; else fail "$1 (missing $2)"; fi
}
missing() { # missing LABEL PATH
  if [[ -e "$2" ]]; then fail "$1 (unexpected $2)"; else pass "$1"; fi
}
valid_tar() { # valid_tar LABEL ARCHIVE
  if tar -tzf "$2" >/dev/null 2>&1; then pass "$1"; else fail "$1 (not a readable tarball)"; fi
}
glob_exists() { # glob_exists LABEL PATTERN
  if compgen -G "$2" >/dev/null; then pass "$1"; else fail "$1 (no path matching $2)"; fi
}

RUN_OUT=""
RUN_STATUS=0
run_installer() { # run_installer PATH [args...]
  local path="$1"; shift
  RUN_OUT="$(env PATH="$path" HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
    XDG_DATA_HOME="$XDG_DATA_HOME" WORKSPACE_ROOT="$WORKSPACE_ROOT" \
    FAKE_ENGINE_STATE="$FAKE_ENGINE_STATE" DEEPSEEK_API_KEY="$DEEPSEEK_API_KEY" \
    WEB_PORT_BASE="$WEB_PORT_BASE" \
    bash "$INSTALLER" "$@" 2>&1 </dev/null)"
  RUN_STATUS=$?
}
run() { run_installer "$PATH" "$@"; }
# run_in_dir runs the installer with a different working directory, for the
# commands whose default output lands in $PWD (backup, rescue --copy).
run_in_dir() { # run_in_dir DIR [args...]
  local dir="$1"; shift
  RUN_OUT="$(cd "$dir" && env PATH="$PATH" HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
    XDG_DATA_HOME="$XDG_DATA_HOME" WORKSPACE_ROOT="$WORKSPACE_ROOT" \
    FAKE_ENGINE_STATE="$FAKE_ENGINE_STATE" DEEPSEEK_API_KEY="$DEEPSEEK_API_KEY" \
    WEB_PORT_BASE="$WEB_PORT_BASE" \
    bash "$INSTALLER" "$@" 2>&1 </dev/null)"
  RUN_STATUS=$?
}
# run_bad_archive makes the engine write an archive that is present but not a
# tarball: the negative control for "verify before keeping".
run_bad_archive() {
  RUN_OUT="$(env PATH="$PATH" HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
    XDG_DATA_HOME="$XDG_DATA_HOME" WORKSPACE_ROOT="$WORKSPACE_ROOT" \
    FAKE_ENGINE_STATE="$FAKE_ENGINE_STATE" DEEPSEEK_API_KEY="$DEEPSEEK_API_KEY" \
    WEB_PORT_BASE="$WEB_PORT_BASE" FAKE_ENGINE_BAD_ARCHIVE=1 \
    bash "$INSTALLER" "$@" 2>&1 </dev/null)"
  RUN_STATUS=$?
}
# run_with_tty runs the installer on a real pty (via `script`), so the interactive
# chooser sees stdin as a terminal exactly as it would for a person; the second
# argument is the line typed at the prompt. This is the one behaviour a pipe
# cannot fake, which is why it uses util-linux `script` rather than a fake fd.
run_with_tty() { # run_with_tty PATH answer [args...]
  local path="$1" answer="$2"; shift 2
  local -a cmd=(env "PATH=$path" "HOME=$HOME" "XDG_CONFIG_HOME=$XDG_CONFIG_HOME"
    "XDG_DATA_HOME=$XDG_DATA_HOME" "WORKSPACE_ROOT=$WORKSPACE_ROOT"
    "FAKE_ENGINE_STATE=$FAKE_ENGINE_STATE" "DEEPSEEK_API_KEY=$DEEPSEEK_API_KEY"
    "WEB_PORT_BASE=$WEB_PORT_BASE" bash "$INSTALLER")
  local arg
  for arg in "$@"; do cmd+=("$arg"); done
  printf '%s\r' "$answer" >"$WORK/pty-answer"
  RUN_OUT="$(script -q -e -c "$(printf '%q ' "${cmd[@]}")" /dev/null \
    <"$WORK/pty-answer" 2>&1)"
  RUN_STATUS=$?
}
# run_same_second runs the installer with a frozen snapshot clock (see
# SAME_SECOND_PATH above), so every snapshot it takes lands in the same second.
run_same_second() { run_installer "$SAME_SECOND_PATH" "$@"; }

# run_piped feeds install.sh to bash on stdin, the way `curl ... | bash -s --`
# does. Every other helper here passes the script as a *file*, which is why the
# documented install command shipped broken: with the script on stdin there is no
# BASH_SOURCE, and reading it under `set -u` aborted the run before it started.
# A checkout has the libraries beside it, so the bootstrap finds them and the test
# stays offline.
run_piped_installer() { # run_piped_installer PATH [args...]
  local path="$1"; shift
  # AW_BOOTSTRAP_FROM_CHECKOUT points the bootstrap at the checkout under test. The
  # install.sh on stdin is the local one, but its checksums are stamped for the
  # *published* ref, so the uncommitted files under test are not there yet - and a
  # real download would silently test the published copy instead of the working
  # tree. Passing a file:// base makes the piped path exercise this repository.
  RUN_OUT="$(env PATH="$path" HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
    XDG_DATA_HOME="$XDG_DATA_HOME" WORKSPACE_ROOT="$WORKSPACE_ROOT" \
    FAKE_ENGINE_STATE="$FAKE_ENGINE_STATE" DEEPSEEK_API_KEY="$DEEPSEEK_API_KEY" \
    WEB_PORT_BASE="$WEB_PORT_BASE" AW_BOOTSTRAP_FROM_CHECKOUT="$ROOT" \
    bash -s -- "$@" <"$INSTALLER" 2>&1)"
  RUN_STATUS=$?
}
run_piped() { run_piped_installer "$PATH" "$@"; }

# run_dead_engine runs the installer once against an engine whose container exits
# the moment it starts, so the liveness check can be asserted.
run_dead_engine() {
  RUN_OUT="$(env PATH="$PATH" HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
    XDG_DATA_HOME="$XDG_DATA_HOME" WORKSPACE_ROOT="$WORKSPACE_ROOT" \
    FAKE_ENGINE_STATE="$FAKE_ENGINE_STATE" DEEPSEEK_API_KEY="$DEEPSEEK_API_KEY" \
    WEB_PORT_BASE="$WEB_PORT_BASE" \
    FAKE_ENGINE_RUN_STATE=stopped CONTAINER_READY_TIMEOUT=0 \
    bash "$INSTALLER" "$@" 2>&1 </dev/null)"
  RUN_STATUS=$?
}

# run_no_key runs the installer with no API key in the environment and no
# terminal, so the credential question cannot be asked at all: whatever it creates
# is a container whose agent has nothing to call a model with.
run_no_key() {
  RUN_OUT="$(env PATH="$PATH" HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
    XDG_DATA_HOME="$XDG_DATA_HOME" WORKSPACE_ROOT="$WORKSPACE_ROOT" \
    FAKE_ENGINE_STATE="$FAKE_ENGINE_STATE" DEEPSEEK_API_KEY="" \
    WEB_PORT_BASE="$WEB_PORT_BASE" \
    bash "$INSTALLER" "$@" 2>&1 </dev/null)"
  RUN_STATUS=$?
}

# run_firstboot_pending runs the installer against a container whose first boot
# has not finished yet: the container runs, but the agent user and therefore the
# web UI cannot exist yet. The first-boot wait is cut to one second so the
# assertion does not sit through the real timeout.
run_firstboot_pending() {
  RUN_OUT="$(env PATH="$PATH" HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
    XDG_DATA_HOME="$XDG_DATA_HOME" WORKSPACE_ROOT="$WORKSPACE_ROOT" \
    FAKE_ENGINE_STATE="$FAKE_ENGINE_STATE" DEEPSEEK_API_KEY="$DEEPSEEK_API_KEY" \
    WEB_PORT_BASE="$WEB_PORT_BASE" FAKE_ENGINE_FIRSTBOOT_PENDING=1 \
    CONTAINER_FIRSTBOOT_TIMEOUT=1 \
    bash "$INSTALLER" "$@" 2>&1 </dev/null)"
  RUN_STATUS=$?
}

# --- host paths ------------------------------------------------------------

data() { printf '%s/agent-workspace' "$XDG_DATA_HOME"; }
meta_key() { sed -n "s/^$2=//p" "$(data)/containers/$1/meta" 2>/dev/null | head -n 1; }
env_path() { printf '%s/containers/%s.env' "$XDG_CONFIG_HOME/agent-workspace" "$1"; }
volume_path() { printf '%s/volumes/agent-workspace-%s-home' "$FAKE_ENGINE_STATE" "$1"; }
fake_state() { cat "$FAKE_ENGINE_STATE/containers/$1/state" 2>/dev/null || printf 'none'; }
snap_root() { printf '%s/snapshots/%s' "$(data)" "$1"; }
snap_ids() { ls "$(snap_root "$1")" 2>/dev/null | sort || true; }
latest_snap() { snap_ids "$1" | tail -n 1; }
snap_count() { snap_ids "$1" | grep -c . || true; }
snap_label() { sed -n 's/^LABEL=//p' "$(snap_root "$1")/$2/meta" 2>/dev/null | head -n 1; }
engine_log() { cat "$FAKE_ENGINE_STATE/log" 2>/dev/null || true; }
remove_container() { # simulate a container that was really removed
  FAKE_ENGINE_NAME=podman FAKE_ENGINE_STATE="$FAKE_ENGINE_STATE" "$FAKE" rm "$1"
}

# =========================================================================
echo "cli"
run --help
is "--help exits 0" 0 "$RUN_STATUS"
contains "--help documents the TUI" "the interactive TUI" "$RUN_OUT"
contains "--help documents create" "install.sh create" "$RUN_OUT"

run --version
is "--version exits 0" 0 "$RUN_STATUS"
contains "--version names the installer" "agent-workspace installer" "$RUN_OUT"

run --help-agents
is "--help-agents exits 0" 0 "$RUN_STATUS"
contains "--help-agents lists dsh" "dsh" "$RUN_OUT"
contains "--help-agents lists opencode" "opencode" "$RUN_OUT"

run no-such-command
is "an unknown command fails" 1 "$RUN_STATUS"
contains "the unknown command is reported" "unknown command" "$RUN_OUT"

run --no-such-flag
is "an unknown option fails" 1 "$RUN_STATUS"
contains "the unknown option is reported" "unknown option" "$RUN_OUT"

run
is "no command without a tty prints usage" 1 "$RUN_STATUS"
contains "the usage is printed" "agent-workspace installer" "$RUN_OUT"

# --- the script on stdin: `curl ... | bash -s -- ...` ----------------------
# These are the cases that only exist when install.sh arrives on stdin instead of
# as a file. They are what the documented command actually does.
run_piped --version
is "a piped install runs instead of aborting" 0 "$RUN_STATUS"
contains "the piped install reports a version" "agent-workspace installer" "$RUN_OUT"
if [[ "$RUN_OUT" == *"unbound variable"* ]]; then
  fail "the piped install died on an unbound variable (BASH_SOURCE has no value when the script is on stdin)"
else
  pass "the piped install does not read BASH_SOURCE unguarded"
fi

run_piped --help
is "a piped --help exits 0" 0 "$RUN_STATUS"
contains "the piped help lists subcommands" "create" "$RUN_OUT"

# With no arguments a piped run cannot start the TUI (stdin is the script), so it
# must say that plainly and name a command that works - not silently do nothing,
# and not bury the explanation under the whole usage text.
run_piped
is "a piped run with no arguments fails loudly" 1 "$RUN_STATUS"
contains "the piped no-argument run says nothing was changed" "nothing was changed" "$RUN_OUT"
contains "the piped no-argument run names a working command" "bash -s --" "$RUN_OUT"
if [[ "$RUN_OUT" == *"BASH_SOURCE"* ]]; then
  fail "the piped no-argument run leaked an internal error instead of explaining the pipe"
else
  pass "the piped no-argument run explains itself without an internal error"
fi

run remove
is "remove without a name fails" 1 "$RUN_STATUS"
contains "remove without a name explains itself" "needs a container name" "$RUN_OUT"

# =========================================================================
# A tag is not a fixed point: `latest` is whatever the registry serves *now*, and
# a local copy of it can be days old. Treating "the image is present" as "the image
# is current" is how a real host created a container from a three-day-old image
# whose dangling /home symlink made the engine die with
# `crun: creating '/home/agent': openat2 'home': No such file or directory` - an
# error that reads like an engine bug and was not one.
echo "image freshness"
DEFAULT_IMAGE="ghcr.io/wraindrock/agent-workspace:latest"
IMAGE_MARKER="$FAKE_ENGINE_STATE/images/$(printf '%s' "$DEFAULT_IMAGE" | tr '/:' '__')"
: >"$IMAGE_MARKER"          # a copy is already here, as after an earlier install
: >"$FAKE_ENGINE_STATE/log" # an empty log makes the next two assertions exact
run create --agent dsh --name fresh1 --yes
is "creating from a tag succeeds" 0 "$RUN_STATUS"
contains "a tag is refreshed before it is used" "podman pull $DEFAULT_IMAGE" "$(engine_log)"
contains "the refreshed copy is named" "refreshed image $DEFAULT_IMAGE" "$RUN_OUT"

: >"$FAKE_ENGINE_STATE/log"
run create --agent dsh --name fresh2 --yes --no-pull
is "create --no-pull uses the local copy" 0 "$RUN_STATUS"
lacks "--no-pull leaves the registry alone" "podman pull" "$(engine_log)"

# A registry can be unreachable. The local copy must still be usable, and the user
# has to be told which copy that is: an old image nobody mentions is the bug.
export FAKE_ENGINE_PULL_FAILS=1
run create --agent dsh --name fresh3 --yes
unset FAKE_ENGINE_PULL_FAILS
is "an unreachable registry still creates from the local copy" 0 "$RUN_STATUS"
contains "the fallback says it is using the local copy" "using the local copy" "$RUN_OUT"
contains "the fallback says when that copy was built" "built 2026-01-02" "$RUN_OUT"

run create --agent dsh --name fresh5 --image ghcr.io/wraindrock/agent-workspace:nope --no-pull --yes
is "a tag that is not here cannot silently succeed" 1 "$RUN_STATUS"
contains "the missing image is named" "ghcr.io/wraindrock/agent-workspace:nope" "$RUN_OUT"

# =========================================================================
# A container with no credentials starts fine and cannot do anything. The key
# question cannot even be asked without a terminal, and that case has to say which
# key was skipped and where it goes - once, not twice in two different wordings.
echo "credentials"
run_no_key create --agent dsh --name nokey --yes
is "creating without a key still succeeds" 0 "$RUN_STATUS"
contains "the skipped key is named" "skipping DEEPSEEK_API_KEY" "$RUN_OUT"
contains "the skipped key is given a home" "add it later to" "$RUN_OUT"
lacks "the missing key is not explained twice" "cannot reach a model" "$RUN_OUT"
missing "no credential file is written when there are no credentials" "$(env_path nokey)"
is "the container without a key is running" running "$(fake_state nokey)"

# =========================================================================
echo "create (persistent)"
run create --agent dsh --name box1 --yes
is "create exits 0" 0 "$RUN_STATUS"
contains "create reports the container" "created box1" "$RUN_OUT"
is "the container is running" running "$(fake_state box1)"
is "the agent is recorded" dsh "$(meta_key box1 AGENT)"
is "the mode is recorded" persistent "$(meta_key box1 MODE)"
is "the engine is recorded" podman "$(meta_key box1 ENGINE)"
is "the volume is recorded" agent-workspace-box1-home "$(meta_key box1 VOLUME)"
exists "the home volume exists" "$(volume_path box1)"
missing "no host workspace directory is created" "$WORKSPACE_ROOT/box1"
contains "the only mount is the engine-managed home volume" \
  "--volume agent-workspace-box1-home:/home/agent" "$(engine_log)"
is "persistent create has exactly one --volume" 1 \
  "$(grep -F -- 'run --name box1' "$FAKE_ENGINE_STATE/log" | grep -o -- '--volume [^ ]*' | wc -l)"
lacks "no host directory is bind-mounted" "$WORKSPACE_ROOT" "$(engine_log)"
contains "the working directory is inside the instance" "--workdir /home/agent" "$(engine_log)"
lacks "the old /workspace working directory is gone" "--workdir /workspace" "$(engine_log)"
exists "the metadata file exists" "$(data)/containers/box1/meta"
exists "the history file exists" "$(data)/containers/box1/meta.history"
contains "the history records the creation" "created from" "$(cat "$(data)/containers/box1/meta.history" 2>/dev/null)"
is "credentials are mode 600" 600 "$(stat -c '%a' "$(env_path box1)" 2>/dev/null)"
contains "credentials hold the API key" "DEEPSEEK_API_KEY=sk-test-dsh-key" "$(cat "$(env_path box1)" 2>/dev/null)"
contains "the credentials were handed to the container" "DEEPSEEK_API_KEY=sk-test-dsh-key" "$(cat "$FAKE_ENGINE_STATE/containers/box1/env" 2>/dev/null)"
contains "podman containers run systemd" "--systemd=always" "$(engine_log)"
contains "the engine is reported" "engine: podman" "$RUN_OUT"

run create --agent dsh --name box1 --yes
is "re-creating a managed container is a no-op" 0 "$RUN_STATUS"
contains "re-creating says it is managed" "already managed" "$RUN_OUT"

run create --agent dsh --name derived --count 2 --yes
is "create --count exits 0" 0 "$RUN_STATUS"
exists "the first counted container exists" "$(data)/containers/derived-1/meta"
exists "the second counted container exists" "$(data)/containers/derived-2/meta"

# =========================================================================
echo "create (ephemeral)"
run create --agent opencode --name once --mode ephemeral --yes
is "create ephemeral exits 0" 0 "$RUN_STATUS"
contains "ephemeral containers run with --rm" "fake ephemeral run" "$(engine_log)"
lacks "ephemeral mounts no host directory" "$WORKSPACE_ROOT" "$(engine_log)"
is "ephemeral create has no --volume" 0 \
  "$(grep -F -- '--rm --name once' "$FAKE_ENGINE_STATE/log" | grep -o -- '--volume [^ ]*' | wc -l)"
contains "ephemeral works inside the instance" "--workdir /home/agent" "$(engine_log)"
is "ephemeral leaves no container behind" none "$(fake_state once)"
is "the ephemeral mode is recorded" ephemeral "$(meta_key once MODE)"
run enter once
is "an ephemeral container cannot be entered" 1 "$RUN_STATUS"
contains "the refusal explains itself" "ephemeral mode" "$RUN_OUT"

# =========================================================================
echo "dry run"
run create --agent dsh --name dry1 --yes --dry-run
is "dry run exits 0" 0 "$RUN_STATUS"
contains "dry run prints the engine command" "dry-run: podman run" "$RUN_OUT"
missing "dry run writes no state" "$(data)/containers/dry1"

# =========================================================================
echo "declaration file"
cat >"$WORK/specs.conf" <<'SPECS'
# name agent [mode] [workspace]
decl1 dsh
decl2 opencode ephemeral
SPECS
run create --file "$WORK/specs.conf" --yes --save "$WORK/saved.conf"
is "create --file exits 0" 0 "$RUN_STATUS"
is "the declared agent is created" dsh "$(meta_key decl1 AGENT)"
is "the declared mode is honoured" ephemeral "$(meta_key decl2 MODE)"
contains "--save writes the resolved declaration" "decl2 opencode ephemeral" "$(cat "$WORK/saved.conf" 2>/dev/null)"

printf 'bad3 nosuchagent\n' >"$WORK/bad-agent.conf"
run create --file "$WORK/bad-agent.conf" --yes
is "an unknown agent in a declaration fails" 1 "$RUN_STATUS"
contains "the unknown agent is reported" "unknown agent" "$RUN_OUT"

printf 'bad!name dsh\n' >"$WORK/bad-name.conf"
run create --file "$WORK/bad-name.conf" --yes
is "an invalid container name in a declaration fails" 1 "$RUN_STATUS"
contains "the invalid name is reported" "invalid container name" "$RUN_OUT"

# =========================================================================
echo "lifecycle"
run stop box1
is "stop exits 0" 0 "$RUN_STATUS"
is "stop stops the container" stopped "$(fake_state box1)"
run list
is "list exits 0" 0 "$RUN_STATUS"
contains "list shows the container" box1 "$RUN_OUT"
contains "list shows the stopped state" stopped "$RUN_OUT"
contains "list shows the agent" dsh "$RUN_OUT"
# No "which backend did it pick?" warning any more: with no auto there is
# nothing to warn about, because the choice is the remembered one.
lacks "list no longer warns about guessing" "more than one backend" "$RUN_OUT"
run start box1
is "start exits 0" 0 "$RUN_STATUS"
is "start starts the container" running "$(fake_state box1)"
run start box1
contains "start is idempotent" "already running" "$RUN_OUT"
run restart box1
is "restart exits 0" 0 "$RUN_STATUS"
is "restart leaves the container running" running "$(fake_state box1)"
run logs box1
contains "logs reach the engine" "fake logs" "$RUN_OUT"
run shell box1
contains "shell opens a login shell" "box1 /bin/bash --login" "$(engine_log)"
run enter box1
contains "enter runs the agent binary" "box1 dsh" "$(engine_log)"
run start ghost
is "starting an unmanaged container fails" 1 "$RUN_STATUS"
contains "the unknown container is reported" "no container named" "$RUN_OUT"

# =========================================================================
echo "snapshots"
mkdir -p "$(volume_path box1)"
printf 'v1\n' >"$(volume_path box1)/secret.txt"
run snapshot box1
is "snapshot exits 0" 0 "$RUN_STATUS"
SNAP="$(latest_snap box1)"
if [[ -n "$SNAP" ]]; then pass "a snapshot id was recorded"; else fail "a snapshot id was recorded"; fi
exists "the snapshot metadata exists" "$(snap_root box1)/$SNAP/meta"
valid_tar "the snapshot archive is a real tarball" "$(snap_root box1)/$SNAP/home.tar.gz"
is "the label defaults to manual" manual "$(snap_label box1 "$SNAP")"
is "the latest snapshot is remembered" "$SNAP" "$(meta_key box1 SNAPSHOT_LAST)"
run snapshots box1
is "snapshots exits 0" 0 "$RUN_STATUS"
contains "snapshots lists the id" "$SNAP" "$RUN_OUT"
contains "snapshots lists the label" "manual" "$RUN_OUT"
run snapshot box1 --label nightly
is "snapshot --label exits 0" 0 "$RUN_STATUS"
is "the custom label is recorded" nightly "$(snap_label box1 "$(latest_snap box1)")"

# =========================================================================
echo "rollback"
printf 'v2\n' >"$(volume_path box1)/secret.txt"
run rollback box1 --to "$SNAP" --yes
is "rollback exits 0" 0 "$RUN_STATUS"
contains "rollback reports the snapshot" "rolled box1 back to snapshot $SNAP" "$RUN_OUT"
is "the volume was restored" v1 "$(cat "$(volume_path box1)/secret.txt" 2>/dev/null)"
is "the container is running again" running "$(fake_state box1)"
is "the rollback image is recorded" "agent-workspace/snapshot-box1:$SNAP" "$(meta_key box1 RUN_IMAGE)"
contains "rollback snapshots the container it replaces" "snapshotting box1 before the rollback" "$RUN_OUT"
contains "rollback reports how much was restored" "entries)" "$RUN_OUT"
PRE_ROLLBACK=""
for id in $(snap_ids box1); do
  if [[ "$(snap_label box1 "$id")" == "pre-rollback" ]]; then PRE_ROLLBACK="$id"; fi
done
if [[ -n "$PRE_ROLLBACK" ]]; then pass "a pre-rollback snapshot exists"; else fail "a pre-rollback snapshot exists"; fi
valid_tar "the pre-rollback archive is a real tarball" "$(snap_root box1)/$PRE_ROLLBACK/home.tar.gz"

BEFORE_SNAPS="$(snap_count box1)"
run rollback box1 --to "$SNAP" --yes --skip-safety
is "rollback --skip-safety exits 0" 0 "$RUN_STATUS"
contains "the skipped safety snapshot is reported" "skipping the safety snapshot" "$RUN_OUT"
is "--skip-safety takes no snapshot" "$BEFORE_SNAPS" "$(snap_count box1)"

# a broken archive must be refused before the container is destroyed
cp "$(snap_root box1)/$SNAP/home.tar.gz" "$WORK/archive.bak"
printf 'broken\n' >"$(snap_root box1)/$SNAP/home.tar.gz"
run rollback box1 --to "$SNAP" --yes
is "rolling back to a corrupt archive fails" 1 "$RUN_STATUS"
contains "the corrupt archive is reported" "unreadable" "$RUN_OUT"
is "the container is left running" running "$(fake_state box1)"
is "the corrupt rollback changed nothing" "agent-workspace/snapshot-box1:$SNAP" "$(meta_key box1 RUN_IMAGE)"
cp "$WORK/archive.bak" "$(snap_root box1)/$SNAP/home.tar.gz"

run rollback box1 --to nope --yes
is "rolling back to an unknown snapshot fails" 1 "$RUN_STATUS"
contains "the unknown snapshot is reported" "not found" "$RUN_OUT"

# =========================================================================
echo "recover"
run stop box1
is "the container is stopped" stopped "$(fake_state box1)"
run recover box1
is "recover exits 0" 0 "$RUN_STATUS"
contains "recover restarts a stopped container" "restarted the existing container" "$RUN_OUT"
run recover box1
contains "recovering a running container is a no-op" "nothing to recover" "$RUN_OUT"

remove_container box1
is "the container is gone" none "$(fake_state box1)"
run recover box1
is "recover from a snapshot exits 0" 0 "$RUN_STATUS"
contains "recover uses the newest snapshot" "recovered box1 from snapshot" "$RUN_OUT"
is "recover brings the container back" running "$(fake_state box1)"

run create --agent dsh --name nosnap --yes
remove_container nosnap
run recover nosnap
is "recover without a snapshot exits 0" 0 "$RUN_STATUS"
contains "recover without a snapshot rebuilds the image" "no snapshot was available" "$RUN_OUT"
is "the rebuilt container runs" running "$(fake_state nosnap)"

run recover ghost
is "recovering an unmanaged container fails" 1 "$RUN_STATUS"
contains "the unmanaged container is reported" "no container named" "$RUN_OUT"

# =========================================================================
echo "fork"
run fork box1 box2 --agent opencode --workspace "$WORKSPACE_ROOT/box2" --yes
is "fork exits 0" 0 "$RUN_STATUS"
contains "fork reports the new container" "forked box1 into box2" "$RUN_OUT"
contains "fork snapshots the source first" "snapshotting box1 before the fork" "$RUN_OUT"
is "the forked container runs" running "$(fake_state box2)"
is "the fork records its origin" box1 "$(meta_key box2 FORKED_FROM)"
is "the fork records the snapshot" "$(latest_snap box1)" "$(meta_key box2 FORKED_AT)"
is "the fork can switch agent" opencode "$(meta_key box2 AGENT)"
is "the fork can switch workspace" "$WORKSPACE_ROOT/box2" "$(meta_key box2 WORKSPACE)"
exists "the forked home volume exists" "$(volume_path box2)"
is "the home volume was copied" v1 "$(cat "$(volume_path box2)/secret.txt" 2>/dev/null)"
exists "the copied credentials exist" "$(env_path box2)"
run fork box1 box2 --yes
is "forking onto an existing container fails" 1 "$RUN_STATUS"
contains "the existing fork target is reported" "already exists" "$RUN_OUT"
run fork box1 local-dir --workspace "$WORKSPACE_ROOT/local-dir" --live --yes
is "fork --live exits 0" 0 "$RUN_STATUS"
contains "fork --live copies the live volume" "copying the live home volume" "$RUN_OUT"
is "the live fork copied the current files" v1 "$(cat "$(volume_path local-dir)/secret.txt" 2>/dev/null)"

# =========================================================================
echo "upgrade"
run upgrade box1 --image ghcr.io/wraindrock/agent-workspace:next --yes
is "upgrade exits 0" 0 "$RUN_STATUS"
contains "upgrade reports the new image" "upgraded box1 to ghcr.io/wraindrock/agent-workspace:next" "$RUN_OUT"
is "the new run image is recorded" "ghcr.io/wraindrock/agent-workspace:next" "$(meta_key box1 RUN_IMAGE)"
UPGRADE_SNAP=""
for id in $(snap_ids box1); do
  if [[ "$(snap_label box1 "$id")" == "pre-upgrade" ]]; then UPGRADE_SNAP="$id"; fi
done
if [[ -n "$UPGRADE_SNAP" ]]; then pass "upgrade snapshots before touching the container"; else fail "upgrade snapshots before touching the container"; fi
is "the upgraded container runs" running "$(fake_state box1)"

run upgrade box1 --no-pull --image ghcr.io/wraindrock/agent-workspace:missing --yes
is "upgrading to an absent image with --no-pull fails" 1 "$RUN_STATUS"
contains "the absent image is reported" "--no-pull" "$RUN_OUT"

# =========================================================================
echo "snapshot pruning"
run create --agent dsh --name prune1 --yes
run snapshot prune1 --keep 2
run snapshot prune1 --keep 2
run snapshot prune1 --keep 2
is "only the newest snapshots are kept" 2 "$(snap_count prune1)"

# =========================================================================
echo "snapshot ids"
# Ids are second-granular and compared as strings, and deleting a snapshot frees
# its id again. Handing out a merely-unused id therefore used to produce an id
# that sorted *before* one that still existed, and `--keep 1` then pruned the very
# snapshot it had just taken. Freezing the clock makes that reachable on demand;
# on a real clock the whole scenario needs two snapshots inside one real second.
run_same_second create --agent dsh --name sameid --yes
run_same_second snapshot sameid --label first
run_same_second snapshot sameid --label second
is "two snapshots inside one second get distinct ids" 2 "$(snap_count sameid)"
run_same_second snapshot sameid --label third --keep 1
is "pruning down to one leaves one" 1 "$(snap_count sameid)"
THIRD_SNAP="$(latest_snap sameid)"
is "the one left is the snapshot just taken" third "$(snap_label sameid "$THIRD_SNAP")"
# Both ids from this second are free again, and one of them sorts before
# ${THIRD_SNAP}: the next snapshot must not take either of them.
run_same_second snapshot sameid --label fourth
FOURTH_SNAP="$(latest_snap sameid)"
if [[ -n "$FOURTH_SNAP" && "$FOURTH_SNAP" > "$THIRD_SNAP" ]]; then
  pass "a snapshot taken after its id was freed still sorts newest"
else
  fail "the new snapshot ${FOURTH_SNAP} does not sort after ${THIRD_SNAP} (ids: $(snap_ids sameid | tr '\n' ' '))"
fi
is "the newest snapshot is the one just taken" fourth "$(snap_label sameid "$FOURTH_SNAP")"
run_same_second snapshot sameid --label fifth --keep 1
FIFTH_SNAP="$(latest_snap sameid)"
is "pruning keeps the snapshot it has just taken" fifth "$(snap_label sameid "$FIFTH_SNAP")"

# =========================================================================
echo "snapshot safety"
# a write that leaves an unreadable archive is not kept as a silent promise
run create --agent dsh --name badarc --yes
mkdir -p "$(volume_path badarc)"
printf 'data\n' >"$(volume_path badarc)/file.txt"
export FAKE_ENGINE_BAD_ARCHIVE=1
run snapshot badarc --label broken
unset FAKE_ENGINE_BAD_ARCHIVE
is "a snapshot with an unreadable home archive exits 0" 0 "$RUN_STATUS"
contains "the unreadable archive is reported" "could not be read back" "$RUN_OUT"
missing "the unreadable archive is deleted" "$(snap_root badarc)/$(latest_snap badarc)/home.tar.gz"
exists "the filesystem snapshot is kept" "$(snap_root badarc)/$(latest_snap badarc)/meta"
run remove badarc --yes

# a snapshot image another container is running from survives pruning
run create --agent dsh --name keeper --yes
run snapshot keeper
KEEP_SNAP="$(latest_snap keeper)"
run rollback keeper --to "$KEEP_SNAP" --yes
run fork keeper keeplive --workspace "$WORKSPACE_ROOT/keeplive" --live --yes
run snapshot keeper --keep 1
contains "pruning reports the container that runs from a snapshot" "still used by" "$RUN_OUT"
exists "the in-use snapshot record is kept" "$(snap_root keeper)/$KEEP_SNAP"
exists "the in-use snapshot image is kept" "$FAKE_ENGINE_STATE/images/agent-workspace_snapshot-keeper_$KEEP_SNAP"
is "the in-use snapshot survives the prune" 2 "$(snap_count keeper)"
# Pruning keeps the newest `--keep N` unprotected snapshots plus every protected one.
# Asserting on a *named* id here is what made this flaky: ids are second-granular, and
# whether the snapshot this run takes sorts after the one already there used to depend
# on the clock (see the "snapshot ids" block above, which pins that down on a frozen
# clock). What is stable regardless of timing: the run takes one new snapshot and then
# prunes to the policy, so the pile still holds the protected snapshot plus the newest
# one, and what disappears is a snapshot that was there before and is not protected.
BEFORE_PILE="$(snap_ids keeper)"
run snapshot keeper --keep 1
is "an unused older snapshot is still pruned" 2 "$(snap_count keeper)"
AFTER_PILE="$(snap_ids keeper)"
if printf '%s\n' "$AFTER_PILE" | grep -qx "$KEEP_SNAP"; then
  pass "the protected snapshot is the one that stayed"
else
  fail "the protected snapshot ${KEEP_SNAP} was pruned (survivors: $(printf '%s' "$AFTER_PILE" | tr '\n' ' '))"
fi
# The snapshot this run took must be the newest one, or the prune would have been
# choosing between ids the clock ordered rather than the policy - which is the defect
# the "snapshot ids" block above exists to catch, not a detail of it.
NEW_SNAP="$(comm -13 <(printf '%s\n' "$BEFORE_PILE" | sort) <(printf '%s\n' "$AFTER_PILE" | sort))"
if [[ -n "$NEW_SNAP" && "$(printf '%s\n' "$AFTER_PILE" | tail -1)" == "$NEW_SNAP" ]]; then
  pass "the snapshot this run took is the newest, so the prune had a real choice"
else
  fail "the new snapshot did not sort newest (before: $(printf '%s' "$BEFORE_PILE" | tr '\n' ' ') / after: $(printf '%s' "$AFTER_PILE" | tr '\n' ' '))"
fi
# Whatever disappeared must have existed before and must not be the protected one.
DROPPED="$(comm -23 <(printf '%s\n' "$BEFORE_PILE" | sort) <(printf '%s\n' "$AFTER_PILE" | sort))"
if [[ -z "$DROPPED" ]]; then
  fail "the prune removed nothing, so it never exercised the excess path"
elif printf '%s\n' "$DROPPED" | grep -qx "$KEEP_SNAP"; then
  fail "the prune removed the protected snapshot ${KEEP_SNAP}"
else
  while IFS= read -r dropped_id; do
    [[ -n "$dropped_id" ]] || continue
    missing "the unused snapshot $dropped_id is gone" "$(snap_root keeper)/$dropped_id"
  done < <(printf '%s\n' "$DROPPED")
fi

# an image a container this installer does not manage still runs from: the engine
# refuses to remove it even though no state file mentions it
run create --agent dsh --name pin1 --yes
run snapshot pin1 --keep 1
PIN_SNAP="$(latest_snap pin1)"
run rollback pin1 --to "$PIN_SNAP" --yes --skip-safety
FAKE_ENGINE_NAME=podman FAKE_ENGINE_STATE="$FAKE_ENGINE_STATE" \
  "$FAKE" run --name sidecar --detach "agent-workspace/snapshot-pin1:$PIN_SNAP" >/dev/null
run upgrade pin1 --image ghcr.io/wraindrock/agent-workspace:next --yes
run snapshot pin1 --keep 1
contains "an engine-only holder is reported" "could not be removed" "$RUN_OUT"
exists "the pinned snapshot is kept" "$(snap_root pin1)/$PIN_SNAP"
remove_container sidecar
run remove pin1 --yes
rm -rf "$(data)/snapshots/pin1"

# =========================================================================
echo "doctor"
run remove once --yes
run remove decl2 --yes
run doctor --strict
is "doctor passes on a healthy host" 0 "$RUN_STATUS"
contains "doctor reports no problems" "no problems found" "$RUN_OUT"
contains "doctor lists the engine" "engine available: podman" "$RUN_OUT"
contains "doctor checks the credentials mode" "mode 600" "$RUN_OUT"
contains "doctor checks snapshot archives" "archive readable" "$RUN_OUT"

rm -rf "$(volume_path box2)"
run doctor --strict
is "doctor fails when a home volume is missing" 1 "$RUN_STATUS"
contains "doctor reports the missing volume" "home volume" "$RUN_OUT"

# =========================================================================
# Backend choice: no auto. Every `run` here feeds the installer /dev/null, so
# these are the non-interactive paths. The list must name every backend with its
# availability, and the remembered file is the only place a choice comes from.
echo "backend choice (no auto)"

run backend
is "backend shows the remembered choice" 0 "$RUN_STATUS"
contains "backend names the remembered backend" "podman" "$RUN_OUT"
contains "backend says it is remembered" "remembered backend" "$RUN_OUT"
# The backend list is the "list" surface: every backend with its availability,
# including the ones this host does not have and the gated incus.
contains "backend lists kvm" "kvm" "$RUN_OUT"
contains "backend lists docker" "docker" "$RUN_OUT"
contains "backend lists incus" "incus" "$RUN_OUT"
contains "backend marks incus not selectable" "not selectable" "$RUN_OUT"
contains "backend marks availability" "available" "$RUN_OUT"

run backend set docker
is "backend set exits 0" 0 "$RUN_STATUS"
contains "backend set confirms the new choice" "remembered backend docker" "$RUN_OUT"
is "backend set writes the remembered choice" "backend=docker" "$(cat "$CONF_DIR/backend")"
is "the remembered choice is mode 600" 600 "$(stat -c '%a' "$CONF_DIR/backend")"
run backend
is "the new choice is reported back" 0 "$RUN_STATUS"
contains "the new choice is reported back" "remembered backend docker" "$RUN_OUT"
run backend set podman
run backend
contains "the choice can be set back" "remembered backend podman" "$RUN_OUT"

run backend set nosuchbackend
is "an unknown backend name is refused" 1 "$RUN_STATUS"
contains "the refusal names the valid backends" "kvm" "$RUN_OUT"
is "a refused name is not written" "backend=podman" "$(cat "$CONF_DIR/backend")"

# The gate: visible in the list, refused as a choice.
run backend set incus
is "remembering incus is refused" 1 "$RUN_STATUS"
contains "the incus refusal explains the gate" "not selectable" "$RUN_OUT"
run --backend incus list
is "--backend incus is refused" 1 "$RUN_STATUS"
contains "the explicit incus refusal explains the gate" "not selectable" "$RUN_OUT"
run --backend incus doctor
contains "the gate message names the implementation" "backend-incus.sh" "$RUN_OUT"
contains "the gate message names the escape hatch" "AW_ENABLE_BACKEND_INCUS" "$RUN_OUT"
run backend
contains "a refused incus is not remembered" "podman" "$RUN_OUT"
lacks "a refused incus did not overwrite the choice" "backend=incus" "$(cat "$CONF_DIR/backend")"

# `--backend` wins for one run and must not write back.
run --backend docker list
is "--backend docker runs" 0 "$RUN_STATUS"
remembered="$(cat "$CONF_DIR/backend")"
is "--backend does not write back to the remembered choice" "backend=podman" "$remembered"
# No remembered choice and no --backend: refuse, print the same list. Moving the
# file aside is what makes this the "brand new user, non-interactive" case.
mv "$CONF_DIR/backend" "$CONF_DIR/backend.saved"
# The refusal is about choosing; --dry-run is planning and still has to work
# for a brand new user, so it assumes podman and says so instead of dying.
run --dry-run list
is "--dry-run without a chosen backend still plans" 0 "$RUN_STATUS"
contains "the dry-run says which backend it assumed" "assumes podman" "$RUN_OUT"
run list
is "no remembered choice and no tty fails" 1 "$RUN_STATUS"
contains "the refusal says how to choose" "--backend" "$RUN_OUT"
contains "the refusal says why it will not choose" "non-interactive" "$RUN_OUT"
contains "the refusal prints the backend list" "podman" "$RUN_OUT"
contains "the printed list includes kvm" "kvm" "$RUN_OUT"
contains "the printed list includes docker" "docker" "$RUN_OUT"
contains "the printed list still includes the gated incus" "incus" "$RUN_OUT"
contains "the printed list warns incus is not selectable" "not selectable" "$RUN_OUT"
# A typo is a usage error before it is a backend question: it must keep
# saying "unknown command" even with no backend chosen.
run frobnicate
is "an unknown command still fails with no backend chosen" 1 "$RUN_STATUS"
contains "the unknown command is named" "unknown command" "$RUN_OUT"
lacks "a typo is not reported as a backend question" "no --backend given" "$RUN_OUT"
mv "$CONF_DIR/backend.saved" "$CONF_DIR/backend"

run list
is "with the choice restored the command runs again" 0 "$RUN_STATUS"

# With a terminal and no remembered choice, the same list is printed and the
# answer is taken from it - then remembered, so the next run does not ask.
mv "$CONF_DIR/backend" "$CONF_DIR/backend.before-chooser"
run_with_tty "$PATH" docker list
is "the interactive chooser exits 0" 0 "$RUN_STATUS"
contains "the chooser prints the list" "trade-off" "$RUN_OUT"
contains "the chooser asks the question" "which backend" "$RUN_OUT"
contains "the chooser confirms what it remembered" "remembered backend docker" "$RUN_OUT"
is "the interactive answer is remembered" "backend=docker" "$(cat "$CONF_DIR/backend")"
is "the remembered file is mode 600" 600 "$(stat -c '%a' "$CONF_DIR/backend")"
run list
is "the next run uses the remembered choice" 0 "$RUN_STATUS"
mv "$CONF_DIR/backend" "$CONF_DIR/backend.after-chooser"
run_with_tty "$PATH" nosuchbackend list
is "a bad answer to the chooser fails" 1 "$RUN_STATUS"
contains "the bad answer is named" "unknown backend 'nosuchbackend'" "$RUN_OUT"
mv "$CONF_DIR/backend.before-chooser" "$CONF_DIR/backend"

# The list shows availability per backend: on this PATH both fakes answer.
run --backend podman doctor
contains "doctor lists the remembered backend preference" "remembered backend: podman" "$RUN_OUT"
contains "the backend list marks availability" "available" "$RUN_OUT"

# =========================================================================
echo "remove"

# A destructive command with nobody to ask must refuse, and must not exit 0. The
# prompt is read from stdin, which `run` feeds /dev/null: the read hits EOF, and
# without this the caller would see the same status as a successful removal.
run remove box1
is "remove without --yes and without a tty fails" 1 "$RUN_STATUS"
contains "remove says why it refused" "refusing to act without confirmation" "$RUN_OUT"
exists "the refused container is still there" "$(data)/containers/box1"
exists "the refused container keeps its volume" "$(volume_path box1)"
lacks "a refused remove does not claim success" "removed box1" "$RUN_OUT"

run remove box2 --yes
is "remove exits 0" 0 "$RUN_STATUS"
contains "remove reports the container" "removed box2" "$RUN_OUT"
missing "the container state is gone" "$(data)/containers/box2"
missing "the home volume is gone" "$(volume_path box2)"
missing "the credentials are gone" "$(env_path box2)"

run remove decl1 --keep-volume --yes
is "remove --keep-volume exits 0" 0 "$RUN_STATUS"
exists "the volume is kept with --keep-volume" "$(volume_path decl1)"

run remove box1 --purge-snapshots --yes
is "remove --purge-snapshots exits 0" 0 "$RUN_STATUS"
missing "the snapshot records are purged" "$(snap_root box1)"
contains "purging keeps the image another container runs from" "runs from it" "$RUN_OUT"
exists "the shared snapshot image survives the purge" \
  "$FAKE_ENGINE_STATE/images/agent-workspace_snapshot-box1_$SNAP"

run remove ghost --yes
is "removing an unmanaged container fails" 1 "$RUN_STATUS"
contains "the unmanaged container is reported" "no container named" "$RUN_OUT"

# =========================================================================
echo "web ui"
run create --agent dsh --name webbox --yes
is "creating a web container exits 0" 0 "$RUN_STATUS"
is "the web UI is enabled by default" 1 "$(meta_key webbox WEB)"
WEB_PORT="$(meta_key webbox WEB_HOST_PORT)"
is "an unused port is assigned automatically" "$WEB_PORT_BASE" "$WEB_PORT"
# The installer does not hand out a URL that answers with a connection reset: the
# container's first boot is what creates the agent user, and the web UI runs as
# that user, so create waits for the boot and then starts the UI itself.
contains "create starts the web UI" \
  "dsh web --patch /usr/share/agent-workspace/dsh-web.yml --no-open" "$(engine_log)"
contains "create prints the sign-in URL" "faketok3n" "$RUN_OUT"
lacks "create does not point at a command it already ran" "install.sh web webbox" "$RUN_OUT"
is "the port is published on the host loopback only" "127.0.0.1:${WEB_PORT}:3080" \
  "$(cat "$FAKE_ENGINE_STATE/containers/webbox/publish" 2>/dev/null || true)"
is "the engine resolves the published port" "127.0.0.1:${WEB_PORT}" \
  "$(FAKE_ENGINE_NAME=podman FAKE_ENGINE_STATE="$FAKE_ENGINE_STATE" "$FAKE" port webbox 3080/tcp)"

run web webbox
is "web exits 0" 0 "$RUN_STATUS"
contains "web prints the loopback URL" "http://127.0.0.1:${WEB_PORT}/" "$RUN_OUT"
contains "web announces the published URL with its port" \
  "http://127.0.0.1:${WEB_PORT}/ (container port" "$RUN_OUT"
lacks "no URL collapses the port into the path" "127.0.0.1/${WEB_PORT}" "$RUN_OUT"
contains "web prints the one-time token link" "?token=faketok3n" "$RUN_OUT"
contains "web starts dsh web with the image overlay" \
  "dsh web --patch /usr/share/agent-workspace/dsh-web.yml --no-open" "$(engine_log)"
run web webbox
is "a second web call exits 0" 0 "$RUN_STATUS"
contains "a second web call reuses the running UI" "already running" "$RUN_OUT"
run web --dry-run webbox
is "web --dry-run exits 0" 0 "$RUN_STATUS"
contains "web --dry-run prints the exec" "dry-run: podman exec --detach" "$RUN_OUT"

# The web UI is a process inside the container, so stopping the container kills
# it. Every path that leaves the container running has to bring it back, or the
# published port answers with a connection reset - which reads as "it did not
# start". A missing webtoken file is how the fake engine says "nothing is
# listening on that port".
rm -f "$FAKE_ENGINE_STATE/containers/webbox/webtoken"
run stop webbox
is "stopping the container exits 0" 0 "$RUN_STATUS"
run start webbox
is "starting a stopped container exits 0" 0 "$RUN_STATUS"
contains "start brings the web UI back" "faketok3n" "$RUN_OUT"

rm -f "$FAKE_ENGINE_STATE/containers/webbox/webtoken"
run restart webbox
is "restarting exits 0" 0 "$RUN_STATUS"
contains "restart brings the web UI back" "faketok3n" "$RUN_OUT"

# a first boot that has not finished: the container runs, the agent user does not
# exist yet, and the installer says so instead of promising a URL
run_firstboot_pending create --agent dsh --name webpending --yes
is "creating while the first boot is pending exits 0" 0 "$RUN_STATUS"
contains "the unfinished first boot is reported" "has not finished its first boot" "$RUN_OUT"
contains "the user is told how to start the UI later" "install.sh web webpending" "$RUN_OUT"
run_firstboot_pending web webpending
is "web on a container still in its first boot fails" 1 "$RUN_STATUS"
contains "the unfinished first boot is explained" "has not finished its first boot" "$RUN_OUT"
run_firstboot_pending start webpending
is "start still exits 0 when the first boot is pending" 0 "$RUN_STATUS"
contains "start warns instead of failing" "has not finished its first boot" "$RUN_OUT"

run list
contains "list shows the published web port" "$WEB_PORT" "$RUN_OUT"

run create --agent dsh --name webpin --web-port 34099 --yes
is "create --web-port exits 0" 0 "$RUN_STATUS"
is "the requested port is recorded" 34099 "$(meta_key webpin WEB_HOST_PORT)"
is "the requested port is published" "127.0.0.1:34099:3080" \
  "$(cat "$FAKE_ENGINE_STATE/containers/webpin/publish" 2>/dev/null || true)"

run create --agent dsh --name webbad --web-port abc --yes
is "a non-numeric --web-port is rejected" 1 "$RUN_STATUS"
contains "the bad port is reported" "--web-port expects a port number" "$RUN_OUT"

run create --agent dsh --name webnone --no-web --yes
is "create --no-web exits 0" 0 "$RUN_STATUS"
is "the web UI is disabled" 0 "$(meta_key webnone WEB)"
missing "no port is published" "$FAKE_ENGINE_STATE/containers/webnone/publish"
run web webnone
is "web on a --no-web container fails" 1 "$RUN_STATUS"
contains "the --no-web container is reported" "--no-web" "$RUN_OUT"

run create --agent dsh --name webtmp --mode ephemeral --yes
is "an ephemeral container is created" 0 "$RUN_STATUS"
run web webtmp
is "web on an ephemeral container fails" 1 "$RUN_STATUS"
contains "the ephemeral container is reported" "ephemeral" "$RUN_OUT"

run create --agent opencode --name weboc --yes
is "an opencode container is created" 0 "$RUN_STATUS"
run web weboc
is "web on an agent without a known UI fails" 1 "$RUN_STATUS"
contains "the missing web UI is reported" "no web UI" "$RUN_OUT"
# Nothing can serve that port, so publishing it would only hand out a URL that
# resets the connection: the port is dropped and the user is told why.
is "an agent with no web UI publishes no port" 0 "$(meta_key weboc WEB)"
missing "no port is published for it" "$FAKE_ENGINE_STATE/containers/weboc/publish"
run create --agent opencode --name webocpin --web-port 34098 --yes
is "asking for a web port on such an agent still exits 0" 0 "$RUN_STATUS"
contains "the ignored web port is explained" "no web UI" "$RUN_OUT"

run web --dry-run ghost
is "web on an unmanaged container fails" 1 "$RUN_STATUS"
contains "the unmanaged container is reported" "no container named" "$RUN_OUT"

# the port is remembered, so a rebuild does not move the published URL
remove_container webbox
run recover webbox --yes
is "recover rebuilds the web container" 0 "$RUN_STATUS"
is "recover reuses the recorded port" "$WEB_PORT" "$(meta_key webbox WEB_HOST_PORT)"
is "recover republishes the same port" "127.0.0.1:${WEB_PORT}:3080" \
  "$(cat "$FAKE_ENGINE_STATE/containers/webbox/publish" 2>/dev/null || true)"

# local-dir and webtmp predate this section; remove them so doctor only judges
# the containers this section manages
run remove local-dir webtmp --yes
run doctor --strict
is "doctor passes with a published web UI" 0 "$RUN_STATUS"
contains "doctor reports the published web UI" "web UI published on 127.0.0.1:${WEB_PORT}" "$RUN_OUT"
rm -f "$FAKE_ENGINE_STATE/containers/webpin/publish"
run doctor --strict
is "doctor fails without the published port" 1 "$RUN_STATUS"
contains "doctor reports the missing web port" "no host port is published" "$RUN_OUT"
run remove webbox webpin webnone weboc webpending webocpin --yes
is "the web test containers are removed" 0 "$RUN_STATUS"

# =========================================================================
echo "engine selection"
# guard: this PATH must offer docker and nothing else, even on a host that has
# a real podman or docker installed
is "the docker-only PATH has no podman" "" \
  "$(env PATH="$DOCKER_ONLY_PATH" sh -c 'command -v podman || true')"
run create --engine docker --agent dsh --name podd --yes
is "--engine docker exits 0" 0 "$RUN_STATUS"
is "the container records docker" docker "$(meta_key podd ENGINE)"
# There is no auto any more, and this PATH offers no podman while podman is the
# remembered choice: the run must refuse (not quietly switch) and it must still
# print the whole list plus the command that changes the choice.
run_installer "$DOCKER_ONLY_PATH" create --agent dsh --name dbox --yes
is "a remembered backend that is not installed fails" 1 "$RUN_STATUS"
contains "the missing remembered backend is named" "podman is not installed" "$RUN_OUT"
contains "the refusal says how to change the choice" "backend set NAME" "$RUN_OUT"
run_installer "$DOCKER_ONLY_PATH" --backend docker create --agent dsh --name dbox --yes
is "--backend docker on a docker-only PATH exits 0" 0 "$RUN_STATUS"
is "the docker container runs" running "$(fake_state dbox)"
contains "docker containers get cgroup mounts" "--cgroupns=host" "$(engine_log)"
# With no remembered choice the explicit flag is the whole story, and its
# message must still name both spellings of the flag.
mv "$CONF_DIR/backend" "$CONF_DIR/backend.saved"
run_installer "$DOCKER_ONLY_PATH" --engine podman doctor
contains "an explicitly requested missing engine names both spellings" \
  "--backend/--engine podman was requested but podman is not installed" "$RUN_OUT"
run_installer "$DOCKER_ONLY_PATH" --backend podman doctor
contains "the --backend spelling is named too" \
  "--backend/--engine podman was requested but podman is not installed" "$RUN_OUT"
mv "$CONF_DIR/backend.saved" "$CONF_DIR/backend"
run_installer "$DOCKER_ONLY_PATH" remove dbox --backend docker --yes
is "a docker container can be removed" 0 "$RUN_STATUS"
missing "the docker container state is gone" "$(data)/containers/dbox"
run_installer "$BIN_NOSH" --help-agents
is "--help-agents works without an engine" 0 "$RUN_STATUS"
contains "--help-agents lists the built-in agents" "dsh" "$RUN_OUT"
run_installer "$BIN_NOSH" create --agent dsh --name engineless --yes
is "creating without an engine fails" 1 "$RUN_STATUS"
contains "the missing engine is reported when there is none" "neither incus, podman nor docker" "$RUN_OUT"
contains "the no-engine refusal still prints the backend list" "kvm" "$RUN_OUT"

# =========================================================================
# =========================================================================
echo "root inside the instance"

# The switch is a live boolean, not a one-time grant: everything asserted here is
# observed through the fake container's files and the argv the installer sent it,
# never by reading the host state alone.
root_creds() { printf '%s/credentials/%s.root' "$CONF_DIR" "$1"; }
root_sudoers() { printf '%s/containers/%s/etc/sudoers.d/agent-workspace' "$FAKE_ENGINE_STATE" "$1"; }

run create --agent dsh --name rootbox --yes
is "creating the root test container exits 0" 0 "$RUN_STATUS"

run root rootbox
is "root with no third word defaults to status" 0 "$RUN_STATUS"
contains "a fresh instance reports root off" "in-instance root for rootbox: OFF" "$RUN_OUT"
contains "status reports the sudoers file is absent" "/etc/sudoers.d/agent-workspace is absent" "$RUN_OUT"
missing "status writes no credentials" "$(root_creds rootbox)"

run root rootbox on
is "root on exits 0" 0 "$RUN_STATUS"
exists "on writes the rule file" "$(root_sudoers rootbox)"
is "the rule file is mode 0440" 440 "$(stat -c '%a' "$(root_sudoers rootbox)" 2>/dev/null)"
contains "the rule grants passwordless sudo" "agent ALL=(ALL) NOPASSWD: ALL" \
  "$(cat "$(root_sudoers rootbox)" 2>/dev/null || true)"
contains "the candidate rule is validated before it goes live" \
  "visudo -cf /etc/sudoers.d/.agent-workspace.tmp" "$(engine_log)"
contains "the validated rule is installed with mode 0440" \
  "install -m 0440 /etc/sudoers.d/.agent-workspace.tmp /etc/sudoers.d/agent-workspace" "$(engine_log)"
contains "on verifies the live probe" "sudo -n true" "$(engine_log)"
exists "on writes the host credentials file" "$(root_creds rootbox)"
is "the credentials file is mode 600" 600 "$(stat -c '%a' "$(root_creds rootbox)" 2>/dev/null)"
contains "on names the credentials file" "$(root_creds rootbox)" "$RUN_OUT"
ROOT_PASSWORD="$(cat "$(root_creds rootbox)" 2>/dev/null || true)"
if [[ "$ROOT_PASSWORD" =~ ^[0-9a-f]{32}$ ]]; then
  pass "the credentials file holds 32 hex characters"
else
  fail "the credentials file should hold 32 hex characters, got [${ROOT_PASSWORD}]"
fi
lacks "the password never reaches stdout or stderr" "$ROOT_PASSWORD" "$RUN_OUT"
lacks "the password never reaches the engine log" "$ROOT_PASSWORD" "$(engine_log)"

run root rootbox status
is "status exits 0 when on" 0 "$RUN_STATUS"
contains "status follows the live probe when on" "in-instance root for rootbox: ON" "$RUN_OUT"
contains "status reports the sudoers file is present" "/etc/sudoers.d/agent-workspace is present" "$RUN_OUT"

# Idempotent in the on direction: re-verify, change nothing. "Change nothing" is
# asserted by the password staying identical and no second chpasswd being sent.
CHPASSWD_BEFORE="$(printf '%s' "$(engine_log)" | grep -c chpasswd || true)"
run root rootbox on
is "on is idempotent" 0 "$RUN_STATUS"
contains "an already-on instance says so" "already on" "$RUN_OUT"
is "already-on leaves the password file alone" "$ROOT_PASSWORD" \
  "$(cat "$(root_creds rootbox)" 2>/dev/null || true)"
is "already-on sets no new password" "$CHPASSWD_BEFORE" \
  "$(printf '%s' "$(engine_log)" | grep -c chpasswd || true)"

run root rootbox off
is "root off exits 0" 0 "$RUN_STATUS"
contains "off reports the instance is off" "in-instance root for rootbox is now off" "$RUN_OUT"
missing "off removes the rule file" "$(root_sudoers rootbox)"
missing "off removes the host credentials file" "$(root_creds rootbox)"
contains "off reports how many credential files it removed" \
  "removed 1 host-side credential file(s)" "$RUN_OUT"
contains "off says running root processes are not revoked" \
  "already-running root processes are not revoked" "$RUN_OUT"
contains "off locks the agent account after rotating its password" "passwd -l agent" "$(engine_log)"

run root rootbox status
is "status exits 0 when off" 0 "$RUN_STATUS"
contains "status follows the live probe when off" "in-instance root for rootbox: OFF" "$RUN_OUT"
contains "status reports the rule file is gone" "/etc/sudoers.d/agent-workspace is absent" "$RUN_OUT"

CHPASSWD_BEFORE="$(printf '%s' "$(engine_log)" | grep -c chpasswd || true)"
run root rootbox off
is "off is idempotent" 0 "$RUN_STATUS"
contains "an already-off instance says so" "already off" "$RUN_OUT"
contains "already-off removes no credential files" "removed 0 host-side credential file(s)" "$RUN_OUT"
is "already-off sets no new password" "$CHPASSWD_BEFORE" \
  "$(printf '%s' "$(engine_log)" | grep -c chpasswd || true)"

# A dry run plans the steps and stops: no rule, no password, no secret.
run root rootbox on --dry-run
is "root dry run exits 0" 0 "$RUN_STATUS"
contains "root dry run prints the engine commands" "dry-run: podman exec rootbox" "$RUN_OUT"
missing "root dry run writes no rule" "$(root_sudoers rootbox)"
missing "root dry run writes no credentials" "$(root_creds rootbox)"

# A sudoers candidate that does not validate must never become live, and must not
# leave a password behind: the failure is before the rule is installed.
run create --agent dsh --name rootbad --yes
RUN_OUT="$(env PATH="$PATH" HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
  XDG_DATA_HOME="$XDG_DATA_HOME" WORKSPACE_ROOT="$WORKSPACE_ROOT" \
  FAKE_ENGINE_STATE="$FAKE_ENGINE_STATE" DEEPSEEK_API_KEY="$DEEPSEEK_API_KEY" \
  WEB_PORT_BASE="$WEB_PORT_BASE" FAKE_ENGINE_BAD_SUDOERS=1 \
  bash "$INSTALLER" root rootbad on 2>&1 </dev/null)"
RUN_STATUS=$?
is "a sudoers rule that fails visudo is refused" 1 "$RUN_STATUS"
contains "the refusal names visudo" "visudo -cf" "$RUN_OUT"
missing "a rejected rule never becomes live" "$(root_sudoers rootbad)"
missing "a rejected rule writes no credentials" "$(root_creds rootbad)"

run root rootbox sideways
is "an unknown root mode fails" 1 "$RUN_STATUS"
contains "the valid modes are named" "on, off, status" "$RUN_OUT"
run root nosuchroot status
is "an unknown instance fails" 1 "$RUN_STATUS"
contains "the unknown instance is reported" "no container named 'nosuchroot'" "$RUN_OUT"

# A stopped instance cannot answer, and the command must say why and how to start
# it instead of guessing from what it can see on the host.
run stop rootbox
run root rootbox on
is "on refuses a stopped instance" 1 "$RUN_STATUS"
contains "the refusal names the start command" "install.sh start rootbox" "$RUN_OUT"
run root rootbox status
is "status refuses to guess about a stopped instance" 1 "$RUN_STATUS"
contains "status explains it cannot verify while stopped" "cannot be verified" "$RUN_OUT"
contains "status explains why that is" "sudo's rules are read inside the instance" "$RUN_OUT"
lacks "status does not report on or off when it could not look" \
  "in-instance root for rootbox:" "$RUN_OUT"
run start rootbox
is "the root test container is running again" 0 "$RUN_STATUS"

# The feature is backend-neutral: it drives the exec verbs, never a backend binary.
root_region="$(sed -n '/^# --- in-instance root/,$p' "$ROOT/installer/lib/commands.sh")"
contains "the root feature goes through the exec verbs" "eng_exec_test" "$root_region"
lacks "the root feature never names podman" "podman" "$root_region"
lacks "the root feature never names docker" "docker" "$root_region"
lacks "the root feature never names incus" "incus" "$root_region"
# =========================================================================
echo "backup / restore / rescue"

run create --agent dsh --name bkp --yes
is "the backup test instance is created" 0 "$RUN_STATUS"
printf 'backup-sentinel\n' >"$(volume_path bkp)/sentinel.txt"
mkdir -p "$WORK/backups"
ARCHIVE="$WORK/backups/bkp.tar.gz"

run backup bkp --to "$ARCHIVE"
is "backup exits 0" 0 "$RUN_STATUS"
exists "backup writes the archive" "$ARCHIVE"
is "the backup archive is private" 600 "$(stat -c %a "$ARCHIVE")"
valid_tar "the backup is a readable tarball" "$ARCHIVE"
is "the manifest is the first archive member" "manifest.txt" "$(tar -tzf "$ARCHIVE" | head -n 1)"
contains "the backup contains the home data" "home/sentinel.txt" "$(tar -tzf "$ARCHIVE")"
contains "the manifest records the instance" "CONTAINER=bkp" "$(tar -xOf "$ARCHIVE" manifest.txt)"
contains "the manifest names the data marker" "DATA=home" "$(tar -xOf "$ARCHIVE" manifest.txt)"
contains "the backup reports its member count" "members" "$RUN_OUT"

run backup bkp --to "$ARCHIVE"
is "backup refuses to overwrite" 1 "$RUN_STATUS"
contains "the overwrite refusal names the file" "$ARCHIVE" "$RUN_OUT"

run backup bkp --to "$WORK/backups/dry.tar.gz" --dry-run
is "backup --dry-run exits 0" 0 "$RUN_STATUS"
contains "backup --dry-run prints the plan" "dry-run: would archive" "$RUN_OUT"
missing "backup --dry-run writes nothing" "$WORK/backups/dry.tar.gz"

mkdir -p "$WORK/cwd"
run_in_dir "$WORK/cwd" backup bkp
is "backup defaults to the current directory" 0 "$RUN_STATUS"
glob_exists "the default name carries the container and a timestamp" \
  "$WORK/cwd/agent-workspace-backup-bkp-*.tar.gz"

run_bad_archive backup bkp --to "$WORK/backups/bad.tar.gz"
is "a backup whose archive is unreadable fails" 1 "$RUN_STATUS"
contains "the unreadable archive is explained" "no archive was kept" "$RUN_OUT"
missing "no partial archive is left behind" "$WORK/backups/bad.tar.gz"

# restore validates the source before it touches anything
run restore bkp "$WORK/backups/nosuch.tar.gz"
is "restore refuses a missing archive" 1 "$RUN_STATUS"
contains "the missing archive is named" "nosuch.tar.gz" "$RUN_OUT"

printf 'not a tarball\n' >"$WORK/backups/broken.tar.gz"
run restore bkp "$WORK/backups/broken.tar.gz"
is "restore refuses an unreadable archive" 1 "$RUN_STATUS"
contains "the unreadable archive is explained" "not a readable tar.gz archive" "$RUN_OUT"

mkdir -p "$WORK/notbackup/home"
printf 'x\n' >"$WORK/notbackup/home/file"
tar czf "$WORK/backups/nomanifest.tar.gz" -C "$WORK/notbackup" home
run restore bkp "$WORK/backups/nomanifest.tar.gz"
is "restore refuses an archive without a manifest" 1 "$RUN_STATUS"
contains "the missing manifest is named" "missing manifest.txt" "$RUN_OUT"

run restore bkp "$ARCHIVE"
is "restore refuses a running instance" 1 "$RUN_STATUS"
contains "the running refusal names the stop command" "install.sh stop bkp" "$RUN_OUT"

run stop bkp
is "the instance stops before restore" 0 "$RUN_STATUS"

volumes_before="$(ls "$FAKE_ENGINE_STATE/volumes" | wc -l)"
run restore bkp "$ARCHIVE" --dry-run
is "restore --dry-run exits 0" 0 "$RUN_STATUS"
contains "restore --dry-run prints the plan" "dry-run: would restore" "$RUN_OUT"
is "restore --dry-run creates no volume" "$volumes_before" "$(ls "$FAKE_ENGINE_STATE/volumes" | wc -l)"
is "restore --dry-run leaves the data alone" "backup-sentinel" "$(cat "$(volume_path bkp)/sentinel.txt")"

printf 'changed-after-backup\n' >"$(volume_path bkp)/sentinel.txt"
run restore bkp "$ARCHIVE"
is "restore exits 0" 0 "$RUN_STATUS"
contains "restore reports the safety snapshot" "safety snapshot:" "$RUN_OUT"
glob_exists "the pre-restore clone exists" \
  "$FAKE_ENGINE_STATE/volumes/agent-workspace-bkp-home-pre-restore-*"
is "restore puts the archived data back" "backup-sentinel" "$(cat "$(volume_path bkp)/sentinel.txt")"
contains "restore reports the volume" "agent-workspace-bkp-home" "$RUN_OUT"
contains "restore reports a count" "entries" "$RUN_OUT"

printf 'changed-again\n' >"$(volume_path bkp)/sentinel.txt"
pre_before="$(ls -d "$FAKE_ENGINE_STATE"/volumes/agent-workspace-bkp-home-pre-restore-* 2>/dev/null | wc -l)"
run restore bkp "$ARCHIVE" --skip-safety
is "restore --skip-safety exits 0" 0 "$RUN_STATUS"
contains "the skipped safety snapshot is stated" "skipping the pre-restore safety snapshot" "$RUN_OUT"
is "restore --skip-safety makes no new clone" "$pre_before" \
  "$(ls -d "$FAKE_ENGINE_STATE"/volumes/agent-workspace-bkp-home-pre-restore-* 2>/dev/null | wc -l)"
is "the skipped restore still restores" "backup-sentinel" "$(cat "$(volume_path bkp)/sentinel.txt")"

run create --agent dsh --name rsc --yes
is "the rescue test instance is created" 0 "$RUN_STATUS"
printf 'rescue-data\n' >"$(volume_path rsc)/take.txt"
run rescue nosuch --copy take.txt
is "rescue refuses an unknown instance" 1 "$RUN_STATUS"
contains "the unknown instance is reported" "no container named" "$RUN_OUT"

run stop rsc
is "the rescue instance stops" 0 "$RUN_STATUS"
run rescue rsc
is "rescue without a terminal refuses an interactive shell" 1 "$RUN_STATUS"
contains "the refusal points at --copy" "--copy PATH" "$RUN_OUT"
is "rescue starts the stopped instance" running "$(fake_state rsc)"

run rescue rsc --copy /etc/passwd
is "rescue refuses a path outside the instance home" 1 "$RUN_STATUS"
contains "the outside path is explained" "outside the instance home" "$RUN_OUT"

mkdir -p "$WORK/rescued"
run_in_dir "$WORK/rescued" rescue rsc --copy take.txt
is "rescue --copy exits 0" 0 "$RUN_STATUS"
exists "rescue copies the path out" "$WORK/rescued/take.txt"
is "the copied file has the data" "rescue-data" "$(cat "$WORK/rescued/take.txt")"
contains "rescue prints the host path" "$WORK/rescued/take.txt" "$RUN_OUT"

run rescue rsc --dry-run
is "rescue --dry-run exits 0" 0 "$RUN_STATUS"
contains "rescue --dry-run prints the plan" "dry-run: would open a root rescue shell" "$RUN_OUT"

run_with_tty "$PATH" "" rescue rsc
is "rescue opens a root shell on a terminal" 0 "$RUN_STATUS"
contains "the rescue shell is a root engine exec" \
  "exec --interactive --tty --user root rsc /bin/bash --login" "$(engine_log)"

echo "create (container that does not stay up)"
# A container that exits on start used to be reported as created, which is how a
# dangling /home and an image without systemd as its command reached a release.
# The installer now waits for the container to run and fails loudly when it does
# not.
run_dead_engine create --agent dsh --name dead1 --yes
is "create fails when the container does not stay up" 1 "$RUN_STATUS"
contains "the failure says the container did not stay up" "did not stay up" "$RUN_OUT"
contains "the failure points at the troubleshooting section" "docs/containers.md#troubleshooting" "$RUN_OUT"

# =========================================================================
echo
printf 'installer tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
