#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# agent-workspace installer.
#
# One command, one way to use this project: on a Linux host, run ./install.sh
# and the TUI creates containers in podman or docker. Each container is a
# complete Linux system built from this repository's image, preconfigured for
# one agent (DSH, OpenCode, ...), and managed so that it can be snapshotted,
# rolled back, recovered and forked.
#
# The installer itself is the only host-side requirement besides a container
# engine: podman is preferred, docker works too.
# ---------------------------------------------------------------------------
set -euo pipefail

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]] || { [[ "${BASH_VERSINFO[0]}" -eq 4 ]] && [[ "${BASH_VERSINFO[1]}" -lt 4 ]]; }; then
  printf 'install.sh needs bash 4.4 or newer (found %s)\n' "${BASH_VERSION:-unknown}" >&2
  exit 1
fi

INSTALLER_HOME="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=installer/lib/engine.sh
source "${INSTALLER_HOME}/installer/lib/engine.sh"
# shellcheck source=installer/lib/state.sh
source "${INSTALLER_HOME}/installer/lib/state.sh"
# shellcheck source=installer/lib/ui.sh
source "${INSTALLER_HOME}/installer/lib/ui.sh"
# shellcheck source=installer/lib/agents.sh
source "${INSTALLER_HOME}/installer/lib/agents.sh"
# shellcheck source=installer/lib/commands.sh
source "${INSTALLER_HOME}/installer/lib/commands.sh"

CONF_HOME="${XDG_CONFIG_HOME:-$HOME/.config}/agent-workspace"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/agent-workspace"
LABEL_NS="agent-workspace"
LABEL_KEY="${LABEL_NS}.manager"
LABEL_VALUE="install.sh"
VOLUME_PREFIX="agent-workspace"
SNAPSHOT_KEEP="${SNAPSHOT_KEEP:-5}"
AGENT_USER="agent"
IMAGE=""
ENGINE_REQUEST="auto"

# The agent web UI is published on the host loopback only. These knobs are read
# by the library functions (installer/lib/commands.sh); see ./install.sh web NAME.
WEB_ENABLED="${WEB_ENABLED:-1}"
WEB_CONTAINER_PORT="${WEB_CONTAINER_PORT:-3080}"
WEB_PORT_BASE="${WEB_PORT_BASE:-3080}"
WEB_HOST_PORT_REQUEST=""

NO_TUI=0
DRY_RUN=0
NO_PULL=0
ASSUME_YES=0
QUIET=0
STRICT=0
PURGE_SNAPSHOTS=0
KEEP_VOLUME=0
# a rollback snapshots the container it is about to replace; --skip-safety turns
# that off when the container is known to be broken beyond snapshotting
SKIP_SAFETY=0
LOGS_FOLLOW=0
LOGS_TAIL=50
FORK_LIVE=0
OPT_AGENT=""
OPT_NAME=""
OPT_COUNT=""
OPT_MODE=""
OPT_WORKSPACE=""
OPT_TO=""
UPGRADE_IMAGE=""
OPT_FROM=""
SNAPSHOT_LABEL=""
DECL_FILE=""
SAVE_FILE=""
SHOW_HELP=0
LEGACY_LIST=0
LEGACY_VERIFY=0
LEGACY_REMOVE=0
EXTRA_ENVS=()
ARGS=()
SPEC_NAME=()
SPEC_AGENT=()
SPEC_MODE=()
SPEC_WORKSPACE=()
declare -A SECRETS=()

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]] && [[ "${TERM:-dumb}" != "dumb" ]]; then
  BOLD=$'\033[1m'
  RED=$'\033[31m'
  GREEN=$'\033[32m'
  YELLOW=$'\033[33m'
  RESET=$'\033[0m'
else
  BOLD=""; RED=""; GREEN=""; YELLOW=""; RESET=""
fi

# --- output ----------------------------------------------------------------

msg()  { [[ "${QUIET:-0}" -eq 1 ]] || printf '%s\n' "$*"; }
heading() { [[ "${QUIET:-0}" -eq 1 ]] || printf '\n%s%s%s\n' "${BOLD}" "$*" "${RESET}"; }
ok()   { [[ "${QUIET:-0}" -eq 1 ]] || printf '%s✓%s %s\n' "${GREEN}" "${RESET}" "$*"; }
warn() { printf '%s!%s %s\n' "${YELLOW}" "${RESET}" "$*" >&2; }
die()  { printf '%s✗%s %s\n' "${RED}" "${RESET}" "$*" >&2; exit 1; }
report_ok()  { printf '%s✓%s %s\n' "${GREEN}" "${RESET}" "$*"; }
report_bad() { printf '%s✗%s %s\n' "${RED}" "${RESET}" "$*"; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'USAGE'
agent-workspace installer

  ./install.sh                 open the interactive TUI (the normal way to use
                               this project: pick agents, name the containers,
                               choose a lifecycle, create them)
  ./install.sh create [opts]   create containers without the TUI
  ./install.sh list            list the containers created by this installer
  ./install.sh enter NAME      run the container's agent interactively
  ./install.sh shell NAME      open a login shell inside a container
  ./install.sh web NAME        start the agent's web UI and print its host URL
  ./install.sh logs NAME       show the container log
  ./install.sh start|stop|restart NAME
  ./install.sh snapshot NAME [--label TEXT] [--keep N]
                               commit the filesystem and archive the home volume
  ./install.sh snapshots NAME  list snapshots of a container
  ./install.sh rollback NAME [--to ID]
                               replace the container with a snapshot
  ./install.sh recover NAME    rebuild a lost or stopped container
  ./install.sh fork SRC NEW [--agent A] [--mode M] [--workspace DIR] [--from ID] [--live]
                               branch a new container off an existing one
  ./install.sh upgrade NAME [--image REF]
                               move a container to a newer image (snapshot first)
  ./install.sh remove NAME...  remove containers (add --purge-snapshots)
  ./install.sh doctor [--strict]
                               check engines, containers, volumes, credentials

create options
  --agent NAME        agent to run (see: install.sh create --help-agents)
  --name NAME         container name (default: <agent>-box)
  --count N           create N containers (N > 1 names them NAME-1..NAME-N)
  --mode MODE         persistent (systemd, keeps state) or ephemeral (run once)
  --workspace DIR     host directory mounted at /workspace
  --env KEY=VALUE     extra environment variable for the container
  --file FILE         read a declaration file ('-' for stdin):
                        name agent [mode] [workspace]
  --save FILE         write the created containers back out in that format

create options for the agent web UI
  --web-port N        host loopback port to publish (default: first free port
                      at or above 3080)
  --no-web            do not publish a web UI port for these containers

global options
  --engine auto|podman|docker   which engine to use (default: auto)
  --image REF                   image to run (default: from image.env)
  --no-tui                      never start the TUI; fail instead of prompting
  --dry-run, -n                 print the engine commands instead of running
  --no-pull                     never pull an image
  --yes, -y                     assume yes for confirmations
  --quiet, -q                   only print warnings and errors
  --strict                      doctor only: exit non-zero on any problem
  --keep N                      snapshot only: keep the newest N snapshots (default 5)
  --purge-snapshots             remove: drop snapshots too
  --keep-volume                 remove: keep the home volume
  --skip-safety                 rollback: do not snapshot the container first
  --follow, -f / --tail N       logs: follow the log / show the last N lines
  --help-agents                 list the agents this build offers
  --help, -h                    this help

host paths
  containers and snapshots:  $XDG_DATA_HOME (default ~/.local/share)/agent-workspace
  credentials (mode 600):    $XDG_CONFIG_HOME (default ~/.config)/agent-workspace/containers
USAGE
}

# --- configuration helpers -------------------------------------------------

# free_web_port BASE prints the first host port at or above BASE that nothing is
# listening on, so a second container does not collide with the first. Without ss
# the base port is used as-is.
free_web_port() {
  local base="${1:-3080}" used candidate i
  if ! have_cmd ss; then
    printf '%s' "$base"
    return 0
  fi
  used="$(ss -H -ltn 2>/dev/null | awk '{print $4}' | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p' || true)"
  for ((i = 0; i < 200; i++)); do
    candidate=$((base + i))
    if ! grep -qx "$candidate" <<<"$used"; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  printf '%s' "$base"
}

env_value() {
  local key="${1}" file="${2}" value=""
  [[ -f "$file" ]] || return 0
  value="$(sed -n "s/^${key}=//p" "$file" | head -n 1)"
  value="${value%\"}"
  value="${value#\"}"
  printf '%s' "$value"
}

default_image() {
  local name org tag
  name="$(env_value IMAGE_NAME "${INSTALLER_HOME}/image.env")"
  org="$(env_value REPO_ORGANIZATION "${INSTALLER_HOME}/image.env")"
  tag="$(env_value DEFAULT_TAG "${INSTALLER_HOME}/image.env")"
  name="${name:-agent-workspace}"
  org="${org:-wraindrock}"
  tag="${tag:-latest}"
  printf 'ghcr.io/%s/%s:%s' "${org,,}" "${name,,}" "$tag"
}

default_workspace() { printf '%s' "${WORKSPACE_ROOT:-$HOME/agent-workspace}/${1}"; }
validate_name() { [[ "${1}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; }

write_env_file() {
  local name="${1}"
  shift
  local path dir kv
  path="$(env_file_for "$name")"
  dir="$(dirname "$path")"
  if [[ "${#}" -eq 0 ]]; then
    msg "no credentials collected for ${name}; you can add them later in ${path}"
    return 0
  fi
  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    printf 'dry-run: would write %s with' "$path"
    for kv in "$@"; do printf ' %s' "${kv%%=*}"; done
    printf '\n'
    return 0
  fi
  install -d -m 0700 "$dir"
  ( umask 077; : >"$path"; chmod 0600 "$path"; for kv in "$@"; do printf '%s\n' "$kv" >>"${path}"; done )
  ok "wrote credentials to ${path} (mode 600)"
}

collect_secret() {
  local agent="${1}" key="${2}" value=""
  [[ -n "${SECRETS[${key}]:-}" ]] && return 0
  if [[ -n "${!key:-}" ]]; then
    SECRETS["${key}"]="${!key}"
    msg "using ${key} from the environment"
    return 0
  fi
  if ! ui_enabled; then
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
      SECRETS["${key}"]="dry-run-placeholder"
    else
      msg "no terminal for prompts: skipping ${key} (add it later to $(env_file_for "$agent"))"
    fi
    return 0
  fi
  value="$(ui_secret "${key} for ${agent} (enter to skip)")" || value=""
  if [[ -n "$value" ]]; then
    SECRETS["${key}"]="${value}"
  fi
  return 0
}

spec_add() {
  SPEC_NAME+=("${1}")
  SPEC_AGENT+=("${2}")
  SPEC_MODE+=("${3}")
  SPEC_WORKSPACE+=("${4}")
}

show_specs() {
  local index
  printf '%-18s %-10s %-11s %s\n' NAME AGENT MODE WORKSPACE
  for index in "${!SPEC_NAME[@]}"; do
    printf '%-18s %-10s %-11s %s\n' "${SPEC_NAME[index]}" "${SPEC_AGENT[index]}" "${SPEC_MODE[index]}" "${SPEC_WORKSPACE[index]}"
  done
}

parse_declaration() {
  local source="${1}" line name agent mode workspace lineno=0
  exec 3<&0
  if [[ "$source" == "-" ]]; then
    exec 0<&3
  else
    [[ -f "$source" ]] || die "declaration file ${source} does not exist"
    exec 0<"$source"
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    line="${line%%#*}"
    # shellcheck disable=SC2086 # the declaration is whitespace separated
    set -- $line
    [[ "${#}" -gt 0 ]] || continue
    name="${1}"; agent="${2:-}"
    mode="${3:-persistent}"; workspace="${4:-}"
    [[ "${#}" -ge 2 ]] || die "${source}:${lineno}: expected 'name agent [mode] [workspace]'"
    validate_name "$name" || die "${source}:${lineno}: invalid container name '${name}'"
    agent_known "$agent" || die "${source}:${lineno}: unknown agent '${agent}'"
    [[ "$mode" == "persistent" || "$mode" == "ephemeral" ]] || die "${source}:${lineno}: unknown mode '${mode}'"
    [[ -n "$workspace" ]] || workspace="$(default_workspace "$name")"
    spec_add "$name" "$agent" "$mode" "$workspace"
  done
  exec 0<&3 3<&-
}

save_specs() {
  local file="${1}" index
  {
    printf '# name agent mode workspace\n'
    for index in "${!SPEC_NAME[@]}"; do
      printf '%s %s %s %s\n' "${SPEC_NAME[index]}" "${SPEC_AGENT[index]}" "${SPEC_MODE[index]}" "${SPEC_WORKSPACE[index]}"
    done
  } >"$file"
  ok "wrote ${file}"
}

# --- create ----------------------------------------------------------------

create_specs() {
  local index name agent mode workspace
  for index in "${!SPEC_NAME[@]}"; do
    name="${SPEC_NAME[index]}"
    agent="${SPEC_AGENT[index]}"
    mode="${SPEC_MODE[index]}"
    workspace="${SPEC_WORKSPACE[index]}"
    if state_exists "$name"; then
      warn "container ${name} is already managed; skipping (remove it first to recreate)"
      continue
    fi
    if eng_container_exists "$name"; then
      warn "a container named ${name} already exists outside this installer; skipping"
      continue
    fi
    heading "Creating ${name} (${agent}, ${mode})"
    if [[ "${DRY_RUN:-0}" -eq 0 ]]; then
      install -d -m 0755 "$workspace" 2>/dev/null || true
    fi
    local -a envs=()
    local key
    for key in $(agent_envs_for "$agent"); do
      [[ -n "${SECRETS[${key}]:-}" ]] && envs+=("${key}=${SECRETS[${key}]}")
    done
    if [[ "${#EXTRA_ENVS[@]}" -gt 0 ]]; then
      envs+=("${EXTRA_ENVS[@]}")
    fi
    if [[ "${DRY_RUN:-0}" -eq 0 ]]; then
      write_env_file "$name" "${envs[@]}"
    fi
    create_container_from "$name" "$agent" "$mode" "$workspace" "$IMAGE"
    ok "created ${name} (agent ${agent}, mode ${mode})"
    if [[ "${DRY_RUN:-0}" -eq 0 && "$(state_get "$name" WEB)" == "1" ]]; then
      local web_port
      web_port="$(state_get "$name" WEB_HOST_PORT)"
      if [[ -n "$web_port" ]]; then
        msg "web UI: install.sh web ${name}  →  http://127.0.0.1:${web_port}/"
      fi
    fi
  done
}

wizard_create() {
  local count index i agent_choice choice name mode workspace key
  ui_header "New agent containers"
  count="$(ui_input "How many containers?" "1")"
  [[ "$count" =~ ^[0-9]+$ ]] && [[ "$count" -ge 1 ]] || die "expected a positive number"
  for ((i = 1; i <= count; i++)); do
    heading "Container ${i} of ${count}"
    local -a items=()
    local a
    while IFS= read -r a; do
      items+=("${a} — $(agent_title_of "$a")")
    done < <(agent_names)
    choice="$(ui_choose "Agent for container ${i}" "${items[@]}")" || die "cancelled"
    agent_choice="${choice%% *}"
    agent_known "$agent_choice" || die "unknown agent '${agent_choice}'"
    local suggested="${agent_choice}-box"
    [[ "$i" -gt 1 ]] && suggested="${agent_choice}-box-${i}"
    name="$(ui_input "Container name" "$suggested")"
    validate_name "$name" || die "invalid container name '${name}'"
    choice="$(ui_choose "Lifecycle for ${name}" \
      "persistent — a running system; state lives in a named volume" \
      "ephemeral — run the agent once, the container is removed on exit")" || die "cancelled"
    mode="${choice%% *}"
    workspace="$(ui_input "Host directory mounted at /workspace" "$(default_workspace "$name")")"
    for key in $(agent_envs_for "$agent_choice"); do
      collect_secret "$agent_choice" "$key"
    done
    spec_add "$name" "$agent_choice" "$mode" "$workspace"
  done
  heading "Summary"
  show_specs
  confirm "Create these containers?" || { warn "aborted"; return 0; }
  create_specs
}

do_create() {
  ensure_image "$IMAGE"
  if [[ -n "$DECL_FILE" ]]; then
    parse_declaration "$DECL_FILE"
  elif [[ -n "$OPT_AGENT" || -n "$OPT_NAME" || -n "$OPT_COUNT" ]]; then
    local agent="${OPT_AGENT:-dsh}" base="${OPT_NAME:-}" count="${OPT_COUNT:-1}" mode="${OPT_MODE:-persistent}" workspace=""
    agent_known "$agent" || die "unknown agent '${agent}'"
    [[ -n "$base" ]] || base="${agent}-box"
    local index name
    for ((index = 1; index <= count; index++)); do
      if [[ "$count" -gt 1 ]]; then
        name="${base}-${index}"
      else
        name="${base}"
      fi
      validate_name "$name" || die "invalid container name '${name}'"
      workspace="${OPT_WORKSPACE:-$(default_workspace "$name")}"
      spec_add "$name" "$agent" "$mode" "$workspace"
      local key
      for key in $(agent_envs_for "$agent"); do
        collect_secret "$agent" "$key"
      done
    done
  elif ui_enabled; then
    wizard_create
  else
    die "nothing to create: pass --agent NAME (and optionally --name/--count), or use --file"
  fi
  if [[ "${#SPEC_NAME[@]}" -eq 0 ]]; then
    warn "no containers were specified"
    return 0
  fi
  show_specs
  if [[ "${ASSUME_YES:-0}" -eq 0 ]] && [[ -z "$DECL_FILE" ]] && ! ui_enabled; then
    die "refusing to create without confirmation"
  fi
  confirm "Create these containers?" || { warn "aborted"; return 0; }
  create_specs
  if [[ -n "$SAVE_FILE" ]]; then
    save_specs "$SAVE_FILE"
  fi
  return 0
}

# --- TUI -------------------------------------------------------------------

pick_container() {
  local header="${1}" names=() line
  while IFS= read -r line; do
    [[ -n "$line" ]] && names+=("$line")
  done < <(state_list)
  if [[ "${#names[@]}" -eq 0 ]]; then
    warn "no containers yet — create one first"
    return 1
  fi
  ui_choose "$header" "${names[@]}"
}

tui_home() {
  local choice name target
  while true; do
    choice="$(ui_choose "agent-workspace — containers for coding agents" \
      "Create a container" \
      "List containers" \
      "Enter a container (run its agent)" \
      "Open a shell in a container" \
      "Open the agent's web UI" \
      "Show the log of a container" \
      "Start / restart a container" \
      "Stop a container" \
      "Snapshot a container" \
      "List snapshots" \
      "Roll a container back" \
      "Recover a container" \
      "Fork a container" \
      "Upgrade a container to a newer image" \
      "Run the doctor" \
      "Remove a container" \
      "Quit")" || return 0
    case "$choice" in
      "Create a container") do_create ;;
      "List containers") cmd_list ;;
      "Enter a container (run its agent)") name="$(pick_container "Which container?")" && cmd_enter "$name" ;;
      "Open a shell in a container") name="$(pick_container "Which container?")" && cmd_enter "$name" /bin/bash --login ;;
      "Open the agent's web UI") name="$(pick_container "Which container?")" && cmd_web "$name" ;;
      "Show the log of a container") name="$(pick_container "Which container?")" && cmd_logs "$name" ;;
      "Start / restart a container") name="$(pick_container "Which container?")" && cmd_restart "$name" ;;
      "Stop a container") name="$(pick_container "Which container?")" && cmd_stop "$name" ;;
      "Snapshot a container")
        name="$(pick_container "Which container?")" || continue
        target="$(ui_input "Label for this snapshot" "manual")"
        cmd_snapshot "$name" "${target:-manual}"
        ;;
      "List snapshots") name="$(pick_container "Which container?")" && cmd_snapshots "$name" ;;
      "Roll a container back")
        name="$(pick_container "Which container?")" || continue
        target="$(ui_input "Snapshot id (enter to use the latest)" "")"
        cmd_rollback "$name" "$target"
        ;;
      "Recover a container") name="$(pick_container "Which container?")" && cmd_recover "$name" ;;
      "Fork a container")
        name="$(pick_container "Fork which container?")" || continue
        target="$(ui_input "Name for the new container" "${name}-fork")"
        cmd_fork "$name" "$target" "" "" "" ""
        ;;
      "Upgrade a container to a newer image")
        name="$(pick_container "Which container?")" || continue
        target="$(ui_input "Image" "$(state_get "$name" IMAGE)")"
        cmd_upgrade "$name" "${target:-$IMAGE}"
        ;;
      "Run the doctor") cmd_doctor ;;
      "Remove a container") name="$(pick_container "Remove which container?")" && cmd_remove "$name" ;;
      "Quit"|"") return 0 ;;
    esac
    printf '\n'
  done
}

# --- dispatch --------------------------------------------------------------

need_arg() {
  [[ "${#ARGS[@]}" -gt 1 ]] || die "'${ARGS[0]}' needs a container name"
}

dispatch() {
  local cmd="${ARGS[0]:-}"
  case "$cmd" in
    create) do_create ;;
    list|ls) cmd_list ;;
    start) need_arg; cmd_start "${ARGS[1]}" ;;
    stop) need_arg; cmd_stop "${ARGS[1]}" ;;
    restart) need_arg; cmd_restart "${ARGS[1]}" ;;
    enter) need_arg; cmd_enter "${ARGS[1]}" ;;
    shell) need_arg; cmd_enter "${ARGS[1]}" /bin/bash --login ;;
    web) need_arg; cmd_web "${ARGS[1]}" ;;
    logs) need_arg; cmd_logs "${ARGS[1]}" ;;
    snapshot) need_arg; cmd_snapshot "${ARGS[1]}" "${SNAPSHOT_LABEL:-manual}" ;;
    snapshots) need_arg; cmd_snapshots "${ARGS[1]}" ;;
    rollback) need_arg; cmd_rollback "${ARGS[1]}" "${OPT_TO:-}" ;;
    recover) need_arg; cmd_recover "${ARGS[1]}" ;;
    fork)
      [[ "${#ARGS[@]}" -ge 3 ]] || die "fork needs a source and a destination: install.sh fork SRC NEW"
      cmd_fork "${ARGS[1]}" "${ARGS[2]}" "${OPT_AGENT:-}" "${OPT_MODE:-}" "${OPT_WORKSPACE:-}" "${OPT_FROM:-}"
      ;;
    upgrade) need_arg; cmd_upgrade "${ARGS[1]}" "${UPGRADE_IMAGE:-${OPT_TO:-}}" ;;
    remove|rm) need_arg; shift_args; remove_many ;;
    doctor) cmd_doctor ;;
    help) usage ;;
    *) die "unknown command '${cmd}' (see: install.sh --help)" ;;
  esac
}

shift_args() { ARGS=("${ARGS[@]:1}"); }

remove_many() {
  local name
  for name in "${ARGS[@]}"; do
    cmd_remove "$name"
  done
}

# --- entry -----------------------------------------------------------------

require_engine() {
  if [[ -z "$(detect_engines)" ]]; then
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
      warn "no container engine found; --dry-run assumes podman"
      ENGINE="podman"
      ENGINE_BIN="podman"
      return 0
    fi
    die "neither podman nor docker is installed; install one of them first"
  fi
  resolve_engine "${ENGINE_REQUEST:-auto}"
  msg "engine: ${ENGINE} ($(eng_version))"
}

parse_args() {
  while [[ "${#}" -gt 0 ]]; do
    case "${1}" in
      --engine) ENGINE_REQUEST="${2}"; shift 2 ;;
      --engine=*) ENGINE_REQUEST="${1#*=}"; shift ;;
      --image) IMAGE="${2}"; UPGRADE_IMAGE="${2}"; shift 2 ;;
      --image=*) IMAGE="${1#*=}"; UPGRADE_IMAGE="${1#*=}"; shift ;;
      --no-tui) NO_TUI=1; shift ;;
      --dry-run|-n) DRY_RUN=1; shift ;;
      --no-pull) NO_PULL=1; shift ;;
      --yes|-y|--assume-yes) ASSUME_YES=1; shift ;;
      --quiet|-q) QUIET=1; shift ;;
      --strict) STRICT=1; shift ;;
      --keep) SNAPSHOT_KEEP="${2}"; shift 2 ;;
      --purge-snapshots) PURGE_SNAPSHOTS=1; shift ;;
      --keep-volume) KEEP_VOLUME=1; shift ;;
      --skip-safety) SKIP_SAFETY=1; shift ;;
      --follow|-f) LOGS_FOLLOW=1; shift ;;
      --tail) LOGS_TAIL="${2}"; shift 2 ;;
      --live) FORK_LIVE=1; shift ;;
      --label) SNAPSHOT_LABEL="${2}"; shift 2 ;;
      --to) OPT_TO="${2}"; shift 2 ;;
      --from) OPT_FROM="${2}"; shift 2 ;;
      --agent) OPT_AGENT="${2}"; shift 2 ;;
      --name) OPT_NAME="${2}"; shift 2 ;;
      --count) OPT_COUNT="${2}"; shift 2 ;;
      --mode) OPT_MODE="${2}"; shift 2 ;;
      --workspace) OPT_WORKSPACE="${2}"; shift 2 ;;
      --env) EXTRA_ENVS+=("${2}"); shift 2 ;;
      --file) DECL_FILE="${2}"; shift 2 ;;
      --save) SAVE_FILE="${2}"; shift 2 ;;
      --web-port) WEB_HOST_PORT_REQUEST="${2}"; shift 2 ;;
      --web-port=*) WEB_HOST_PORT_REQUEST="${1#*=}"; shift ;;
      --no-web) WEB_ENABLED=0; shift ;;
      --list) LEGACY_LIST=1; shift ;;
      --verify) LEGACY_VERIFY=1; shift ;;
      --remove) LEGACY_REMOVE=1; shift ;;
      --help|-h) SHOW_HELP=1; shift ;;
      --version|-V) printf '%s\n' "agent-workspace installer (image ${IMAGE:-default})"; exit 0 ;;
      --help-agents) SHOW_AGENTS=1; shift ;;
      --) shift; ARGS+=("${@}"); break ;;
      -*) die "unknown option ${1} (see: install.sh --help)" ;;
      *) ARGS+=("${1}"); shift ;;
    esac
  done
}

main() {
  parse_args "$@"
  if [[ "${SHOW_HELP:-0}" -eq 1 ]]; then
    usage
    return 0
  fi
  [[ -n "$IMAGE" ]] || IMAGE="$(default_image)"
  AGENT_USER="$(env_value AGENT_USER "${INSTALLER_HOME}/image.env")"
  AGENT_USER="${AGENT_USER:-agent}"

  if [[ -n "${WEB_HOST_PORT_REQUEST:-}" ]] && [[ ! "$WEB_HOST_PORT_REQUEST" =~ ^[0-9]+$ ]]; then
    die "--web-port expects a port number, got '${WEB_HOST_PORT_REQUEST}'"
  fi

  if [[ "${SHOW_AGENTS:-0}" -eq 1 ]]; then
    # the built-in catalogue does not need an engine, and the image catalogue
    # is only consulted when the image is already present locally
    load_agents
    local a
    while IFS= read -r a; do
      printf '%-12s %-28s %s\n' "$a" "$(agent_binary_of "$a")" "$(agent_title_of "$a")"
    done < <(agent_names)
    return 0
  fi

  if [[ "${LEGACY_LIST:-0}" -eq 1 ]]; then
    require_engine
    cmd_list
    return 0
  fi
  if [[ "${LEGACY_VERIFY:-0}" -eq 1 ]]; then
    require_engine
    cmd_doctor
    return 0
  fi
  if [[ "${LEGACY_REMOVE:-0}" -eq 1 ]]; then
    require_engine
    shift_args
    remove_many
    return 0
  fi

  if [[ "${#ARGS[@]}" -eq 0 ]]; then
    if ! ui_enabled; then
      usage
      return 1
    fi
    ensure_gum || true
    if [[ -z "$GUM_BIN" ]]; then
      usage
      return 1
    fi
    require_engine
    load_agents
    tui_home
    return 0
  fi

  require_engine
  load_agents
  dispatch
}

main "$@"
