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
# keep auto-assigned web ports out of the well-known range a real host may use
export WEB_PORT_BASE=34700

BIN="$WORK/bin"
BIN_DOCKER="$WORK/bin-docker"
# A PATH that offers the everyday tools but no container engine at all. The
# engine selection tests build on this instead of on /usr/bin, so they never
# pick up a real podman or docker just because the host (or a CI runner) has
# one installed.
BIN_NOSH="$WORK/bin-nosh"
mkdir -p "$BIN" "$BIN_DOCKER" "$BIN_NOSH" "$HOME" "$WORKSPACE_ROOT" "$FAKE_ENGINE_STATE"

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
  mktemp uniq tee sha256sum realpath readlink stat hostname seq which; do
  tool_path="$(command -v "$tool" 2>/dev/null || true)"
  [[ -n "$tool_path" ]] && ln -sf "$tool_path" "$BIN_NOSH/$tool"
done

# a PATH that offers docker and nothing else, for the engine selection tests
DOCKER_ONLY_PATH="$BIN_DOCKER:$BIN_NOSH"

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
exists "the workspace directory exists" "$WORKSPACE_ROOT/box1"
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
contains "list warns about the engine choice" "both podman and docker are installed" "$RUN_OUT"
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
# Pruning keeps the newest `--keep 1` unprotected snapshots plus every protected
# one, and deletes the excess in between. Asserting on a *named* id is what made
# this flaky: snapshot ids are second-granular and a collision is disambiguated by
# appending `b`, so three snapshots taken within one second sort as
# `...Z`, `...Zb`, `...Zbb`. With `...Z` protected (both `keeper` and `keeplive`
# run from its image) the prune deletes the middle one, and both `latest_snap` and
# "newest unprotected" name `...Zbb` - the id the prune deliberately keeps. In CI
# all three landed in the same second and the assertion failed while passing here.
#
# What is stable regardless of timing: `snapshot keeper --keep 1` creates one new
# snapshot and then prunes down to the policy, so the survivors are the protected
# one plus the newest; a pre-existing unprotected snapshot is what disappears, and
# the protected record plus its image survive. Asserting on set difference keeps
# this independent of second-granularity ids.
BEFORE_PILE="$(snap_ids keeper)"
run snapshot keeper --keep 1
is "an unused older snapshot is still pruned" 2 "$(snap_count keeper)"
AFTER_PILE="$(snap_ids keeper)"
if printf '%s\n' "$AFTER_PILE" | grep -qx "$KEEP_SNAP"; then
  pass "the protected snapshot is the one that stayed"
else
  fail "the protected snapshot ${KEEP_SNAP} was pruned (survivors: $(printf '%s' "$AFTER_PILE" | tr '\n' ' '))"
fi
# the snapshot that disappeared must be one that existed before and is not protected
DROPPED="$(comm -23 <(printf '%s\n' "$BEFORE_PILE" | sort) <(printf '%s\n' "$AFTER_PILE" | sort))"
if [[ -z "$DROPPED" ]]; then
  fail "the prune removed nothing, so it never exercised the excess path"
elif [[ "$(printf '%s\n' "$DROPPED" | grep -c .)" -ne 1 ]]; then
  fail "the prune removed more than one snapshot: $(printf '%s' "$DROPPED" | tr '\n' ' ')"
elif [[ "$DROPPED" == "$KEEP_SNAP" ]]; then
  fail "the prune removed the protected snapshot ${KEEP_SNAP}"
else
  missing "the unused snapshot is gone" "$(snap_root keeper)/$DROPPED"
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
echo "remove"
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
contains "create points at the web command" "install.sh web webbox" "$RUN_OUT"
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
run remove webbox webpin webnone weboc --yes
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
run_installer "$DOCKER_ONLY_PATH" create --agent dsh --name dbox --yes
is "docker is detected when it is the only engine" 0 "$RUN_STATUS"
is "the docker container runs" running "$(fake_state dbox)"
contains "docker containers get cgroup mounts" "--cgroupns=host" "$(engine_log)"
run_installer "$DOCKER_ONLY_PATH" --engine podman doctor
is "requesting a missing engine fails" 1 "$RUN_STATUS"
contains "the missing engine is reported" "--engine podman was requested but podman is not installed" "$RUN_OUT"
run_installer "$DOCKER_ONLY_PATH" remove dbox --yes
is "a docker container can be removed" 0 "$RUN_STATUS"
missing "the docker container state is gone" "$(data)/containers/dbox"
run_installer "$BIN_NOSH" --help-agents
is "--help-agents works without an engine" 0 "$RUN_STATUS"
contains "--help-agents lists the built-in agents" "dsh" "$RUN_OUT"
run_installer "$BIN_NOSH" create --agent dsh --name engineless --yes
is "creating without an engine fails" 1 "$RUN_STATUS"
contains "the missing engine is reported when there is none" "neither podman nor docker" "$RUN_OUT"

# =========================================================================
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
