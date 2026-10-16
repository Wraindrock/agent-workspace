#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Behavioral assertions for the Incus backend.
#
# A fake `incus` (plus a fake podman and xz for the image export) records every
# command the backend issues and keeps the state the backend reads back, so the
# mapping can be asserted without a daemon: what an instance is created with,
# how the home is stored, how the port is read, and what happens when the daemon
# accepts a credential it does not keep.
#
# What this file cannot prove is that the real CLI accepts these commands:
# `shift=true` on a disk device, `--alias` on image import, `config set ... -`
# for a value on stdin. That needs a daemon the user starts once
# (`sudo systemctl enable --now incus.socket && sudo incus admin init --minimal`);
# until then the backend is asserted here and marked as unverified in the docs.
# ---------------------------------------------------------------------------
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
backend="${repo_root}/installer/lib/backend-incus.sh"
engine="${repo_root}/installer/lib/engine.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/aw-incus-test.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

failures=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  fail %s\n' "$1"; failures=$((failures + 1)); }

mkdir -p "$WORK/bin"
export FAKE_INCUS_STATE="$WORK/state" FAKE_INCUS_LOG="$WORK/log"
export FAKE_PODMAN_LOG="$WORK/podman-log"
: >"$FAKE_INCUS_LOG"
: >"$FAKE_PODMAN_LOG"

# --- the fake daemon -------------------------------------------------------
cat >"$WORK/bin/incus" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
state="${FAKE_INCUS_STATE:?}"; log="${FAKE_INCUS_LOG:?}"
mkdir -p "$state/instances" "$state/running" "$state/config" "$state/devices"
printf '%s\n' "$*" >>"$log"
cmd="${1:-}"; shift || true
case "$cmd" in
  --version) printf '6.23\n' ;;
  info)      [[ -e "$state/instances/${1:-}" ]] && exit 0; exit 1 ;;
  list)
    shopt -s nullglob
    if [[ -z "${1:-}" || "${1:-}" == --* ]]; then
      for f in "$state"/instances/*; do printf '%s,CONTAINER\n' "$(basename "$f")"; done
    else
      name="$1"
      [[ -e "$state/instances/$name" ]] || exit 0
      if [[ -e "$state/running/$name" ]]; then printf 'RUNNING\n'; else printf 'STOPPED\n'; fi
    fi ;;
  init)     name="${2:-}"; mkdir -p "$state/instances"; : >"$state/instances/$name" ;;
  start)    mkdir -p "$state/running"; : >"$state/running/${1:-}" ;;
  stop)     rm -f "$state/running/${1:-}" ;;
  delete)
    for a in "$@"; do
      case "$a" in --*) ;; *) rm -rf "$state/instances/$a" "$state/running/$a" "$state/config/$a" "$state/devices/$a"; break ;; esac
    done ;;
  publish)  : ;;
  console)  printf 'fake-console-log\n' ;;
  exec)     [[ -f "$state/exec-status" ]] && exit "$(cat "$state/exec-status")"; exit 0 ;;
  config)
    sub="${1:-}"; shift || true
    case "$sub" in
      set)
        name="$1"; key="$2"; value="${3:-}"
        if [[ "$value" == "-" ]]; then
          if [[ "${FAKE_INCUS_DROP_STDIN:-0}" == "1" ]]; then value="-"; else value="$(cat)"; fi
        fi
        mkdir -p "$state/config/$name"
        printf '%s' "$value" >"$state/config/$name/$key" ;;
      get)
        file="$state/config/${1:-}/${2:-}"
        [[ -r "$file" ]] || exit 1
        cat "$file"; printf '\n' ;;
      device)
        dsub="${1:-}"; shift || true
        case "$dsub" in
          add)
            name="$1"; dev="$2"; shift 2
            mkdir -p "$state/devices/$name"
            printf '%s\n' "$*" >"$state/devices/$name/$dev" ;;
          get)
            file="$state/devices/${1:-}/${2:-}"
            [[ -r "$file" ]] || exit 1
            tr ' ' '\n' <"$file" | sed -n "s/^${3:-}=//p" ;;
        esac ;;
    esac ;;
  image)
    sub="${1:-}"; shift || true
    case "$sub" in
      alias)  [[ -r "$state/aliases" ]] && cat "$state/aliases" || true ;;
      import)
        while [[ $# -gt 0 ]]; do
          case "$1" in --alias) printf '%s\n' "$2" >>"$state/aliases"; shift 2 ;; *) shift ;; esac
        done ;;
      list)   printf 'abcdef0123456789abcdef\n' ;;
      delete) grep -vx -- "${1:-}" "$state/aliases" >"$state/aliases.tmp" 2>/dev/null || true
              mv "$state/aliases.tmp" "$state/aliases" 2>/dev/null || true ;;
    esac ;;
  *) : ;;
esac
FAKE

cat >"$WORK/bin/podman" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >>"${FAKE_PODMAN_LOG:?}"
case "${1:-}" in
  --version) printf 'podman version 5.0.0\n' ;;
  create)    printf 'ctr123\n' ;;
  export)    printf 'fake-rootfs-stream\n' ;;
  image)     [[ "${2:-}" == inspect ]] && printf '%s\n' "${FAKE_PODMAN_ID:-sha256:1111111111111111}" ;;
esac
exit 0
FAKE

# The image export pipes through xz; a passthrough keeps the test independent of
# a real compressor.
cat >"$WORK/bin/xz" <<'FAKE'
#!/usr/bin/env bash
cat
FAKE

chmod +x "$WORK/bin/incus" "$WORK/bin/podman" "$WORK/bin/xz"

# run_backend <snippet>: run it with the backend loaded, under the same strict
# mode the installer runs with, so an errexit violation fails here too.
run_backend() {
  local snippet="$1"
  (
    set -euo pipefail
    export ENGINE=incus ENGINE_BIN="$WORK/bin/incus"
    export FAKE_INCUS_STATE FAKE_INCUS_LOG FAKE_PODMAN_LOG
    export INCUS_STATE_DIR="$WORK/incus"
    export INCUS_HOMES_DIR="$WORK/incus/homes"
    export INCUS_IMAGES_DIR="$WORK/incus/images"
    export LABEL_KEY=io.github.wraindrock.agent-workspace
    export LABEL_VALUE=1
    export LABEL_NS=io.github.wraindrock.aw
    export AGENT_USER=agent
    export WEB_CONTAINER_PORT=3080
    export PATH="$WORK/bin:$PATH"
    die_k() { printf 'die_k: %s\n' "$*" >&2; exit 1; }
    # shellcheck source=/dev/null
    source "$engine"
    # shellcheck source=/dev/null
    source "$backend"
    eval "$snippet"
  )
}

home_dir() { printf '%s/incus/homes/%s\n' "$WORK" "$1"; }
log_has()  { grep -qF -- "$1" "$FAKE_INCUS_LOG"; }
podman_log_has() { grep -qF -- "$1" "$FAKE_PODMAN_LOG"; }
log_count() { grep -cF -- "$1" "$FAKE_INCUS_LOG" || true; }

# --- interface facts -------------------------------------------------------
echo "interface"
# The interface is verbs, not capability flags: what a backend cannot do, it does
# the long way round. An Incus instance snapshot would not contain this
# workspace's home - it is a host directory, not part of the instance - so the
# backend must own the commit + home-archive path and must not define a native
# snapshot verb that would quietly lose the agent's data.
if run_backend 'declare -F eng_commit >/dev/null && declare -F eng_volume_archive >/dev/null && declare -F eng_volume_restore_archive >/dev/null && declare -F eng_volume_clone >/dev/null && ! declare -F eng_snapshot_create >/dev/null && ! declare -F eng_snapshot_restore >/dev/null' >/dev/null 2>&1; then
  pass "snapshots go through commit + home archive, and no native-snapshot verb is defined"
else
  fail "the incus backend does not define the commit + home-archive snapshot path"
fi
if [[ -z "$(run_backend 'engine_mount_suffix')" ]]; then
  pass "mounts are left to the daemon (no podman-style ':z' suffix)"
else
  fail "engine_mount_suffix returned '$(run_backend 'engine_mount_suffix')' for a backend that labels its own mounts"
fi

# The loader sources this file under `set -euo pipefail`; a bare read that can
# fail (a missing key, a daemon that answers nothing) would abort the installer
# at the top level instead of being handled.
if run_backend 'declare -F eng_create_persistent >/dev/null && declare -F eng_pull >/dev/null && declare -F engine_mount_suffix >/dev/null' >/dev/null 2>&1; then
  pass "the backend loads under set -euo pipefail and defines the interface"
else
  fail "the backend does not load under set -euo pipefail"
fi

# --- the home is an ordinary directory -------------------------------------
echo "home storage"
run_backend 'eng_volume_create hom1' >/dev/null || fail "eng_volume_create failed"
if [[ -d "$(home_dir hom1)" ]] && [[ "$(stat -c %a "$(home_dir hom1)")" == "700" ]]; then
  pass "eng_volume_create makes a 0700 directory"
else
  fail "eng_volume_create did not make a 0700 directory"
fi
printf 'notes\n' >"$(home_dir hom1)/note.txt"
mkdir -p "$WORK/arch"
run_backend 'eng_volume_archive hom1 '"$WORK"'/arch img' >/dev/null || fail "eng_volume_archive failed"
if [[ -s "$WORK/arch/home.tar.gz" ]] && tar tzf "$WORK/arch/home.tar.gz" | grep -q './note.txt'; then
  pass "eng_volume_archive tars the home without a container"
else
  fail "eng_volume_archive did not produce an archive with ./note.txt"
fi
run_backend 'eng_volume_restore_archive hom2 '"$WORK"'/arch/home.tar.gz img' >/dev/null || fail "eng_volume_restore_archive failed"
if [[ -f "$(home_dir hom2)/note.txt" ]]; then
  pass "eng_volume_restore_archive restores into another home"
else
  fail "eng_volume_restore_archive restored nothing"
fi
run_backend 'eng_volume_clone hom2 hom3' >/dev/null || fail "eng_volume_clone failed"
if [[ -f "$(home_dir hom3)/note.txt" ]]; then
  pass "eng_volume_clone copies the home (the fork path)"
else
  fail "eng_volume_clone copied nothing"
fi
run_backend 'eng_volume_remove hom3' >/dev/null || fail "eng_volume_remove failed"
if [[ ! -d "$(home_dir hom3)" ]]; then
  pass "eng_volume_remove drops the directory"
else
  fail "eng_volume_remove left the directory"
fi
# A name with a slash must never reach rm -rf outside the homes directory.
run_backend 'eng_volume_remove ../escaped' >/dev/null 2>&1 || true
if [[ -d "$WORK/incus/homes" ]]; then
  pass "eng_volume_remove refuses a name that escapes the homes directory"
else
  fail "eng_volume_remove deleted outside the homes directory"
fi

# --- dry run must not touch the host --------------------------------------
echo "dry run"
rm -rf "$(home_dir hom9)"
out="$(DRY_RUN=1 run_backend 'eng_volume_create hom9' 2>&1)" || true
if [[ ! -d "$(home_dir hom9)" ]] && [[ "$out" == *"dry-run:"* ]] && [[ "$out" == *"homes/hom9"* ]]; then
  pass "a dry run prints the command and creates nothing"
else
  fail "a dry run changed the host or printed nothing (out: ${out})"
fi

# --- the image pipeline ----------------------------------------------------
# An instance can only be created from an image the daemon already has, so this
# runs before the create section (the installer pulls before it creates too).
echo "image import"
: >"$FAKE_INCUS_LOG"
rm -rf "$WORK/incus/images"
if run_backend 'eng_image_exists ghcr.io/x/agent:1'; then
  fail "eng_image_exists said yes before anything was imported"
else
  pass "eng_image_exists is false before the import"
fi
run_backend 'eng_pull ghcr.io/x/agent:1' >/dev/null 2>&1 || fail "eng_pull failed"
# The registry half of the pipeline is the other CLI's log; the daemon half is
# this backend's.
for want in "pull ghcr.io/x/agent:1" "create ghcr.io/x/agent:1" "export ctr123" "rm --force ctr123"; do
  if podman_log_has "$want"; then
    pass "eng_pull issues: ${want}"
  else
    fail "eng_pull did not issue: ${want}"
  fi
done
for want in "image import" "--alias aw-ghcr.io_x_agent_1"; do
  if log_has "$want"; then
    pass "eng_pull issues: ${want}"
  else
    fail "eng_pull did not issue: ${want}"
  fi
done
if [[ -s "$WORK/incus/images/aw-ghcr.io_x_agent_1.id" ]]; then
  pass "the imported image id is recorded for the next run"
else
  fail "the imported image id was not recorded"
fi
run_backend 'eng_pull ghcr.io/x/agent:1' >/dev/null 2>&1 || true
if [[ "$(log_count 'image import')" == "1" ]]; then
  pass "pulling the same image twice imports once"
else
  fail "pulling the same image twice imported $(log_count 'image import') times"
fi
# A moving tag: the id under the tag changed, so what is imported is stale.
FAKE_PODMAN_ID=sha256:2222222222222222 run_backend 'eng_pull ghcr.io/x/agent:1' >/dev/null 2>&1 || true
if [[ "$(log_count 'image import')" == "2" ]] && log_has "image delete aw-ghcr.io_x_agent_1"; then
  pass "a changed image id replaces the imported rootfs"
else
  fail "a changed image id did not re-import (count $(log_count 'image import'))"
fi
if [[ -n "$(run_backend 'eng_image_id ghcr.io/x/agent:1')" ]]; then
  pass "eng_image_id reports the imported image"
else
  fail "eng_image_id reported nothing"
fi

# --- creating an instance --------------------------------------------------
echo "create"
cat >"$WORK/creds.env" <<'ENV'
# a comment
DEEPSEEK_API_KEY=sk-test-secret-value
ENV
: >"$FAKE_INCUS_LOG"
run_backend 'eng_create_persistent box ghcr.io/x/agent:1 hom4 '"$WORK"'/ws "$WORK/creds.env" 3081 agent' >/dev/null \
  || fail "eng_create_persistent failed"
for want in \
  "init aw-ghcr.io_x_agent_1 box" \
  "config set box user.io.github.wraindrock.agent-workspace 1" \
  "config device add box home disk source=$WORK/incus/homes/hom4 path=/home/agent shift=true" \
  "config device add box workspace disk source=$WORK/ws path=/workspace shift=true" \
  "config device add box web proxy listen=tcp:127.0.0.1:3081 connect=tcp:127.0.0.1:3080" \
  "start box"; do
  if log_has "$want"; then
    pass "create issues: ${want}"
  else
    fail "create did not issue: ${want}"
  fi
done
# Both credentials go in over stdin, so argv keeps the key and a dash.
for key in AGENT_WORKSPACE_AGENT DEEPSEEK_API_KEY; do
  if log_has "config set box environment.${key} -"; then
    pass "create passes ${key} without putting it on the command line"
  else
    fail "create did not pass ${key} over stdin"
  fi
done

# The credential must reach the daemon on stdin, and must never be part of a
# command line (argv is visible in ps and in the shell's history file).
if grep -q 'sk-test-secret-value' "$FAKE_INCUS_LOG"; then
  fail "the credential appeared in a command line"
else
  pass "the credential never appears in a command line"
fi
if [[ "$(cat "$FAKE_INCUS_STATE/config/box/environment.DEEPSEEK_API_KEY" 2>/dev/null)" == "sk-test-secret-value" ]]; then
  pass "the credential arrived through stdin"
else
  fail "the credential did not arrive through stdin"
fi

# Read-only verbs against the fake daemon.
out="$(run_backend 'eng_container_running box && printf running; eng_container_status box; eng_container_image box; eng_host_port box 3081; printf "|"; eng_host_port box 9999')" || true
if [[ "$out" == "runningrunning"*"ghcr.io/x/agent:1"*"127.0.0.1:3081"*"|" ]]; then
  pass "running/status/image/host-port read back from the daemon"
else
  fail "read-only verbs answered '${out}'"
fi
if [[ -z "$(run_backend 'eng_host_port box 9999')" ]]; then
  pass "a port the instance does not publish answers with nothing"
else
  fail "a port the instance does not publish answered with an address"
fi

# A daemon that accepts a value and does not keep it must stop the create
# instead of starting an agent that has no credentials.
echo "credential verification"
: >"$FAKE_INCUS_LOG"
if FAKE_INCUS_DROP_STDIN=1 run_backend 'eng_create_persistent bad ghcr.io/x/agent:1 hom5 '"$WORK"'/ws "$WORK/creds.env" 3082 agent' >/dev/null 2>&1; then
  fail "a daemon that drops the value still produced an instance"
else
  if log_has "start bad"; then
    fail "the unverified instance was started anyway"
  else
    pass "an unkept credential aborts before start"
  fi
fi

# --- the rest of the verbs -------------------------------------------------
echo "verbs"
: >"$FAKE_INCUS_LOG"
run_backend 'eng_exec_background box agent "dsh web --no-open"' >/dev/null || fail "eng_exec_background failed"
if log_has "exec box --user agent --env HOME=/home/agent -- /bin/bash -c" && grep -q 'setsid --fork' "$FAKE_INCUS_LOG"; then
  pass "eng_exec_background starts the command in its own session as the agent"
else
  fail "eng_exec_background did not detach the command as the agent"
fi
out="$(run_backend 'eng_logs box 5')" || true
if [[ "$out" == *"fake-console-log"* ]]; then
  pass "eng_logs reads the instance console log"
else
  fail "eng_logs printed '${out}'"
fi
run_backend 'eng_commit box snap1' >/dev/null || fail "eng_commit failed"
if log_has "publish box --alias snap1"; then
  pass "eng_commit publishes the instance as an image"
else
  fail "eng_commit did not publish"
fi
run_backend 'eng_stop box; eng_remove box' >/dev/null || fail "stop/remove failed"
if log_has "delete --force box" && [[ ! -e "$FAKE_INCUS_STATE/instances/box" ]]; then
  pass "eng_remove deletes the instance and nothing else"
else
  fail "eng_remove did not delete the instance"
fi

# --- preference order ------------------------------------------------------
echo "preference"
names="$(run_backend 'backend_names')" || true
if [[ "$(printf '%s\n' "$names" | head -n 1)" == "incus" ]]; then
  pass "backend_names puts incus first when the daemon answers"
else
  fail "backend_names answered '$(printf '%s' "$names" | paste -sd, -)'"
fi

echo
if [[ "$failures" -eq 0 ]]; then
  echo "incus: all checks passed"
  exit 0
fi
echo "incus: ${failures} check(s) failed"
exit 1
