#!/usr/bin/env bash
# Integration tests for the host installer (install.sh).
#
# podman is faked, so this runs anywhere and never touches a real container
# engine: it checks the commands the installer would run, the files it writes
# and the exit codes it returns.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$*" >&2; }

assert_contains() {
  local haystack="$1" needle="$2" what="$3"
  if [[ "$haystack" == *"$needle"* ]]; then ok "$what"; else fail "$what (missing: $needle)"; fi
}

assert_absent() {
  local haystack="$1" needle="$2" what="$3"
  if [[ "$haystack" != *"$needle"* ]]; then ok "$what"; else fail "$what (unexpected: $needle)"; fi
}

assert_file() { if [[ -f "$1" ]]; then ok "$2"; else fail "$2 (no such file: $1)"; fi; }
assert_no_file() { if [[ ! -e "$1" ]]; then ok "$2"; else fail "$2 (still present: $1)"; fi; }

BIN="$WORK/bin"
STATE=""
LOG=""
mkdir -p "$BIN"

cat > "$BIN/podman" <<'FAKE'
#!/usr/bin/env bash
# Fake podman used by tests/install.sh: records every call and answers the
# queries the installer makes. It is part of the test, never shipped.
set -uo pipefail

log_file="${FAKE_LOG:?}"
state="${FAKE_STATE:?}"
mkdir -p "$state"
printf 'podman %s\n' "$*" >> "$log_file"

case "${1:-}" in
  --version)
    printf 'podman version 9.9.9-fake\n'
    exit 0
    ;;
  image)
    if [[ "${2:-}" == "exists" ]]; then
      if [[ -f "$state/image" && "$(cat "$state/image")" == "${3:-}" ]]; then exit 0; else exit 1; fi
    fi
    ;;
  pull)
    printf '%s' "${2:-}" > "$state/image"
    exit 0
    ;;
  container)
    if [[ "${2:-}" == "exists" ]]; then
      if [[ -f "$state/container-${3:-}" ]]; then exit 0; else exit 1; fi
    fi
    ;;
  volume)
    if [[ "${2:-}" == "exists" ]]; then
      if [[ -f "$state/volume-${3:-}" ]]; then exit 0; else exit 1; fi
    fi
    if [[ "${2:-}" == "rm" ]]; then
      rm -f "$state/volume-${3:-}"
      exit 0
    fi
    ;;
  ps)
    fmt=""
    for arg in "$@"; do
      case "$arg" in
        *Names*) fmt="$arg" ;;
      esac
    done
    for f in "$state"/container-*; do
      if [[ ! -e "$f" ]]; then continue; fi
      name="${f##*container-}"
      if [[ "$fmt" == *Status* ]]; then printf '%s\trunning\n' "$name"; else printf '%s\n' "$name"; fi
    done
    exit 0
    ;;
  inspect)
    fmt="${3:-}"
    name="${4:-}"
    case "$fmt" in
      *agent-workspace.agent*) cat "$state/agent-$name" 2>/dev/null || printf '\n' ;;
      *agent-workspace.mode*) cat "$state/mode-$name" 2>/dev/null || printf '\n' ;;
      *State.Status*) printf 'running\n' ;;
      *) printf '\n' ;;
    esac
    exit 0
    ;;
  exec)
    exit 0
    ;;
  rm)
    name="${3:-}"
    rm -f "$state/container-$name" "$state/agent-$name" "$state/mode-$name"
    exit 0
    ;;
  run)
    name=""
    agent=""
    mode=""
    entrypoint=""
    volume=""
    i=1
    while [[ $i -le $# ]]; do
      arg="${!i}"
      case "$arg" in
        --entrypoint) i=$((i + 1)); entrypoint="${!i}" ;;
        --name) i=$((i + 1)); name="${!i}" ;;
        --volume)
          i=$((i + 1))
          volume="${!i}"
          case "$volume" in
            agent-workspace-*-home:*) : > "$state/volume-${volume%%:*}" ;;
          esac
          ;;
        --label)
          i=$((i + 1))
          case "${!i}" in
            agent-workspace.agent=*) agent="${!i}"; agent="${agent#*=}" ;;
            agent-workspace.mode=*) mode="${!i}"; mode="${mode#*=}" ;;
          esac
          ;;
      esac
      i=$((i + 1))
    done
    if [[ "$entrypoint" == "/usr/bin/jq" ]]; then
      printf 'dsh\tdsh\tDSH (DeepSeek Harness)\tDEEPSEEK_API_KEY\n'
      printf 'opencode\topencode\tOpenCode\tDEEPSEEK_API_KEY\n'
      exit 0
    fi
    if [[ -n "$name" ]]; then
      : > "$state/container-$name"
      printf '%s' "$agent" > "$state/agent-$name"
      printf '%s' "$mode" > "$state/mode-$name"
    fi
    exit 0
    ;;
esac

exit 0
FAKE
chmod +x "$BIN/podman"

new_state() {
  STATE="$WORK/state-$1"
  rm -rf "$STATE"
  mkdir -p "$STATE"
  LOG="$WORK/log-$1"
  : > "$LOG"
}

run_installer() {
  local home="$1"
  shift
  mkdir -p "$home"
  HOME="$home" XDG_CONFIG_HOME="$home/.config" PODMAN="$BIN/podman" \
    FAKE_LOG="$LOG" FAKE_STATE="$STATE" DEEPSEEK_API_KEY="sk-test-key" \
    "$ROOT/install.sh" "$@"
}

printf 'installer\n'

# --- help -------------------------------------------------------------------
out="$(run_installer "$WORK/home-help" --help 2>&1)"
assert_contains "$out" "Usage:" "--help prints the usage text"
assert_contains "$out" "--file FILE" "--help documents the declarative mode"
if run_installer "$WORK/home-help" -- --help >/dev/null 2>&1; then
  ok "-- ends option parsing"
else
  fail "-- ends option parsing"
fi

# --- declarative file, credentials taken from the environment ---------------
new_state decl
cat > "$WORK/containers.conf" <<CONF
# name agent mode workspace
dev-dsh dsh persistent $WORK/ws/dev-dsh
scratch opencode ephemeral
CONF
out="$(run_installer "$WORK/home-decl" --file "$WORK/containers.conf" --yes --image test/image:latest 2>&1)"
rc=$?
if ((rc == 0)); then ok "a declaration file creates the containers"; else fail "a declaration file creates the containers (exit $rc): $out"; fi
if [[ -d "$WORK/ws/dev-dsh" ]]; then ok "the workspace directory is created"; else fail "the workspace directory is created"; fi
logs="$(cat "$LOG")"
assert_contains "$logs" "--name dev-dsh" "creates the persistent container"
assert_contains "$logs" "--systemd=always" "boots systemd in the persistent container"
assert_contains "$logs" "agent-workspace-dev-dsh-home:/home/agent" "persists the container home"
assert_contains "$logs" "--label agent-workspace.agent=opencode" "labels the ephemeral container"
assert_contains "$logs" "--rm --interactive --tty" "runs the ephemeral container one-shot"
assert_contains "$logs" "test/image:latest opencode" "passes the agent binary as the command"
envfile="$WORK/home-decl/.config/agent-workspace/containers/scratch.env"
assert_file "$envfile" "writes a credential file"
assert_contains "$(cat "$envfile" 2>/dev/null)" "DEEPSEEK_API_KEY=sk-test-key" "stores the API key from the environment"
mode="$(stat -c '%a' "$envfile" 2>/dev/null || stat -f '%Lp' "$envfile" 2>/dev/null)"
if [[ "$mode" == "600" ]]; then ok "the credential file is mode 600"; else fail "the credential file is mode 600 (got '$mode')"; fi

# --- --save round trip ------------------------------------------------------
saved="$WORK/saved.conf"
new_state save
run_installer "$WORK/home-save" --file "$WORK/containers.conf" --yes --image test/image:latest --save "$saved" >/dev/null 2>&1
assert_file "$saved" "--save writes a declaration file"
assert_contains "$(cat "$saved" 2>/dev/null)" "dev-dsh" "--save records the container name"
new_state replay
out="$(run_installer "$WORK/home-replay" --file "$saved" --yes --dry-run --image test/image:latest 2>&1)"
assert_contains "$out" "--name scratch" "the saved declaration can be replayed"

# --- dry run leaves nothing behind -----------------------------------------
new_state dry
out="$(run_installer "$WORK/home-dry" --file "$WORK/containers.conf" --yes --dry-run --image test/image:latest 2>&1)"
assert_contains "$out" "--systemd=always" "--dry-run prints the podman command"
assert_absent "$(cat "$LOG")" "run --detach" "--dry-run does not create containers"
assert_no_file "$WORK/home-dry/.config/agent-workspace/containers/dev-dsh.env" "--dry-run writes no credential file"

# --- list, verify, remove ---------------------------------------------------
new_state manage
run_installer "$WORK/home-manage" --file "$WORK/containers.conf" --yes --image test/image:latest >/dev/null 2>&1
out="$(run_installer "$WORK/home-manage" --list 2>&1)"
assert_contains "$out" "dev-dsh" "--list shows the container"
assert_contains "$out" "dsh" "--list shows which agent it runs"
out="$(run_installer "$WORK/home-manage" --verify 2>&1)"
rc=$?
if ((rc == 0)); then ok "--verify exits 0 for healthy containers"; else fail "--verify exits 0 for healthy containers (exit $rc): $out"; fi
assert_contains "$out" "can run dsh" "--verify checks the agent binary"
run_installer "$WORK/home-manage" --remove dev-dsh --yes >/dev/null 2>&1
logs="$(cat "$LOG")"
assert_contains "$logs" "rm --force dev-dsh" "--remove deletes the container"
assert_contains "$logs" "volume rm agent-workspace-dev-dsh-home" "--remove deletes the home volume"
assert_no_file "$WORK/home-manage/.config/agent-workspace/containers/dev-dsh.env" "--remove deletes the credential file"

# --- declaration on stdin, and bulk naming ----------------------------------
new_state stdin
out="$(printf 'box dsh ephemeral\n' | run_installer "$WORK/home-stdin" --file - --yes --image test/image:latest 2>&1)"
rc=$?
if ((rc == 0)); then ok "--file - reads the declaration from stdin"; else fail "--file - reads the declaration from stdin (exit $rc): $out"; fi
assert_contains "$(cat "$LOG")" "--name box" "creates the container declared on stdin"

new_state bulk
run_installer "$WORK/home-bulk" --agent dsh --count 2 --name box --yes --image test/image:latest >/dev/null 2>&1
logs="$(cat "$LOG")"
assert_contains "$logs" "--name box " "bulk mode names the first container"
assert_contains "$logs" "--name box-2" "bulk mode numbers the remaining containers"

# --- an empty host is not an error -----------------------------------------
new_state empty
out="$(run_installer "$WORK/home-empty" --list 2>&1)"
assert_contains "$out" "none yet" "--list on a fresh host says so"

# --- bad input is refused ---------------------------------------------------
new_state bad
printf 'x nope\n' > "$WORK/bad-agent.conf"
printf 'x/y dsh\n' > "$WORK/bad-name.conf"
if run_installer "$WORK/home-bad" --file "$WORK/bad-agent.conf" --yes --image test/image:latest >/dev/null 2>&1; then
  fail "an unknown agent is refused"
else
  ok "an unknown agent is refused"
fi
if run_installer "$WORK/home-bad" --file "$WORK/bad-name.conf" --yes --image test/image:latest >/dev/null 2>&1; then
  fail "an invalid container name is refused"
else
  ok "an invalid container name is refused"
fi
if run_installer "$WORK/home-bad" --agent dsh --mode bogus --yes --image test/image:latest >/dev/null 2>&1; then
  fail "an invalid mode is refused"
else
  ok "an invalid mode is refused"
fi
if run_installer "$WORK/home-bad" --definitely-not-an-option >/dev/null 2>&1; then
  fail "an unknown flag is refused"
else
  ok "an unknown flag is refused"
fi
new_state nopull
if run_installer "$WORK/home-nopull" --file "$WORK/containers.conf" --no-pull --yes --image missing/image:latest >/dev/null 2>&1; then
  fail "--no-pull with a missing image is refused"
else
  ok "--no-pull with a missing image is refused"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if ((FAIL > 0)); then exit 1; fi
exit 0
