#!/usr/bin/env bash
# agent-workspace installer -- create and manage agent sandbox containers.
#
# The image ships the agents; this script only decides how many containers
# exist, what they are called, which agent each one starts, and how they get
# their credentials. Nothing here rebuilds the image.
#
#   ./install.sh                            interactive wizard
#   ./install.sh --file containers.conf     declarative, non-interactive
#   ./install.sh --list                     list the containers it manages
#   ./install.sh --verify                   check that they still work
#   ./install.sh --remove NAME              delete a container and its data
#
# Every container carries the label agent-workspace.manager=install.sh, so the
# tool only ever sees (and deletes) its own containers.
set -euo pipefail

PROG="$(basename -- "$0")"
REPO_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"

PODMAN="${PODMAN:-podman}"
IMAGE="${IMAGE:-}"
CONF_HOME="${XDG_CONFIG_HOME:-$HOME/.config}/agent-workspace"
ENV_DIR="${CONF_HOME}/containers"
LABEL_KEY="agent-workspace.manager"
LABEL_VALUE="install.sh"
VOLUME_PREFIX="agent-workspace"

DRY_RUN=0
NO_PULL=0
REPLACE=0
ASSUME_YES=0
QUIET=0
ACTION=""
DECL_FILE=""
SAVE_FILE=""
OPT_AGENT=""
OPT_NAME=""
OPT_MODE=""
OPT_WORKSPACE=""
OPT_COUNT=""
EXTRA_ENVS=()
EXTRA_ARGS=()

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
else
  BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; RESET=""
fi

# --- output -----------------------------------------------------------------

msg() { printf '%s\n' "$*"; }

heading() {
  if [[ "${QUIET}" -eq 0 ]]; then printf '\n%s%s%s\n' "$BOLD" "$*" "$RESET"; fi
}

ok() {
  if [[ "${QUIET}" -eq 0 ]]; then printf '  %sok%s   %s\n' "$GREEN" "$RESET" "$*"; fi
}

warn() { printf '  %swarn%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }

die() { printf '%serror%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

have_cmd() { command -v -- "$1" >/dev/null 2>&1; }

usage() {
  cat <<'USAGE'
agent-workspace installer

Usage:
  ./install.sh [options]

Interactive (default):
  ./install.sh                      asks how many containers to create, what to
                                    call them, which agent each one runs,
                                    persistent or ephemeral, and can store the
                                    agent's API key.

Declarative:
  --file FILE                       create the containers listed in FILE ("-"
                                    reads the list from stdin). Lines are:
                                      # name        agent     mode        workspace
                                      dev-dsh       dsh       persistent  ~/agent-workspace/dev-dsh
                                      scratch       opencode  ephemeral
  --save FILE                       after a successful run, write the created
                                    containers to FILE in that same format

What to create:
  --agent NAME                      agent to run (default: ask; dsh when not
                                    interactive)
  --name NAME                       first container name (default:
                                    agent-workspace-AGENT)
  --count N                         create N containers in one go
  --mode persistent|ephemeral       persistent (default): systemd stays up, you
                                    exec into it; ephemeral: podman run --rm,
                                    gone as soon as the agent exits
  --workspace DIR                   host directory mounted at /workspace
  --env KEY=VALUE                   environment variable for the container
                                    (repeatable)
  --image REF                       image to run (default: image.env or GHCR)
  --extra-arg ARG                   extra podman argument (repeatable)

Managing what exists:
  --list                            list containers created by this installer
  --verify                          check the containers and their agent binaries
  --remove NAME                     remove a container, its home volume and its
                                    credential file

Other:
  --dry-run, -n                     print the podman commands instead of running
  --no-pull                         never pull the image
  --replace                         recreate a container that already exists
  --yes, -y                         assume yes for confirmations
  --quiet                           less output
  --help, -h                        this text

Environment:
  PODMAN                            podman binary to use (default: podman)
  IMAGE                             default image, same as --image
  DEEPSEEK_API_KEY                  used for dsh/opencode instead of prompting
  NO_COLOR                          disable coloured output

Credentials live in ~/.config/agent-workspace/containers/NAME.env (mode 0600)
and are handed to the container with --env-file.
USAGE
}

# --- small helpers ----------------------------------------------------------

env_value() {
  local key="$1" file="$2" line
  [[ -r "$file" ]] || return 1
  line="$(grep -E "^[[:space:]]*${key}=" "$file" | tail -n1)" || return 1
  line="${line#*=}"
  line="${line%\"}"
  line="${line#\"}"
  printf '%s' "$line"
}

default_image() {
  local name="agent-workspace" org="Wraindrock" tag="latest" value
  if [[ -r "${REPO_DIR}/image.env" ]]; then
    value="$(env_value IMAGE_NAME "${REPO_DIR}/image.env" || true)"
    if [[ -n "$value" ]]; then name="$value"; fi
    value="$(env_value REPO_ORGANIZATION "${REPO_DIR}/image.env" || true)"
    if [[ -n "$value" ]]; then org="$value"; fi
    value="$(env_value DEFAULT_TAG "${REPO_DIR}/image.env" || true)"
    if [[ -n "$value" ]]; then tag="$value"; fi
  fi
  printf 'ghcr.io/%s/%s:%s' "${org,,}" "${name,,}" "$tag"
}

default_workspace() { printf '%s' "${HOME}/agent-workspace/$1"; }

env_file_path() { printf '%s' "${ENV_DIR}/$1.env"; }

validate_name() {
  if [[ ! "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
    die "invalid container name '$1': use letters, digits, dot, dash or underscore"
  fi
}

validate_mode() {
  case "$1" in
    persistent|ephemeral) return 0 ;;
    *) die "invalid mode '$1': expected persistent or ephemeral" ;;
  esac
}

confirm() {
  local question="$1" answer
  printf '%s? [Y/n] ' "$question" >&2
  read -r answer || return 1
  case "${answer:-y}" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

# --- the agent list ---------------------------------------------------------

AGENT_NAMES=()
AGENT_BINS=()
AGENT_TITLES=()
AGENT_ENVS=()

# Used when the image cannot be queried (no podman access, older image).
default_agents() {
  printf '%s\t%s\t%s\t%s\n' dsh dsh 'DSH (DeepSeek Harness)' DEEPSEEK_API_KEY
  printf '%s\t%s\t%s\t%s\n' opencode opencode 'OpenCode' DEEPSEEK_API_KEY
}

# The image knows best which agents it ships: it publishes an agent catalogue
# in manifest.json. Run the image's own jq so the host needs nothing but podman.
image_agents() {
  local filter
  filter='if ((.agentCatalog // {}) | length) > 0 then .agentCatalog | to_entries[] | [.key, ((.value.binaries // []) | join(" ")), (.value.title // ""), ((.value.env // []) | join(" "))] | @tsv else (.agentBinaries // {}) | to_entries[] | [.key, ((.value // []) | join(" ")), .key, ""] | @tsv end'
  "$PODMAN" run --rm --entrypoint /usr/bin/jq "$IMAGE" -r "$filter" /usr/share/agent-workspace/manifest.json 2>/dev/null || true
}

agents_from_table() {
  local name bins title envs
  while IFS=$'\t' read -r name bins title envs; do
    if [[ -z "$name" ]]; then continue; fi
    AGENT_NAMES+=("$name")
    AGENT_BINS+=("${bins%% *}")
    if [[ -n "$title" ]]; then AGENT_TITLES+=("$title"); else AGENT_TITLES+=("$name"); fi
    AGENT_ENVS+=("${envs:-}")
  done <<< "$1"
}

load_agents() {
  local table=""
  AGENT_NAMES=(); AGENT_BINS=(); AGENT_TITLES=(); AGENT_ENVS=()
  if have_cmd "${PODMAN}" || [[ -x "${PODMAN}" ]]; then
    table="$(image_agents)"
  fi
  if [[ -z "$table" ]]; then
    table="$(default_agents)"
    warn "could not read the agent catalogue from ${IMAGE}; using the built-in list"
  fi
  agents_from_table "$table"
  if [[ "${#AGENT_NAMES[@]}" -eq 0 ]]; then agents_from_table "$(default_agents)"; fi
  if [[ "${#AGENT_NAMES[@]}" -eq 0 ]]; then die "no agents are available"; fi
}

agent_index() {
  local name="$1" i
  for ((i = 0; i < ${#AGENT_NAMES[@]}; i++)); do
    if [[ "${AGENT_NAMES[i]}" == "$name" ]]; then printf '%s' "$i"; return 0; fi
  done
  return 1
}

agent_binary_of() {
  local idx
  if idx="$(agent_index "$1")"; then printf '%s' "${AGENT_BINS[idx]}"; return 0; fi
  printf '%s' "$1"
}

agent_title_of() {
  local idx
  if idx="$(agent_index "$1")"; then printf '%s' "${AGENT_TITLES[idx]}"; return 0; fi
  printf '%s' "$1"
}

# --- credentials ------------------------------------------------------------

declare -A SECRETS=()

# Pick up credentials that are already in the environment, unless the user
# typed one in during this run.
collect_ambient_secrets() {
  local agent="$1" idx key ambient
  idx="$(agent_index "$agent")" || return 0
  [[ -n "${AGENT_ENVS[idx]:-}" ]] || return 0
  local -a vars=()
  read -r -a vars <<< "${AGENT_ENVS[idx]}"
  for key in "${vars[@]}"; do
    if [[ -n "${SECRETS[$key]:-}" ]]; then continue; fi
    ambient="${!key}"
    if [[ -n "$ambient" ]]; then
      SECRETS[$key]="$ambient"
      ok "${key} taken from this shell's environment"
    fi
  done
}

write_env_file() {
  local name="$1"; shift
  local path entry key old_umask
  if [[ $# -eq 0 ]]; then return 0; fi
  path="$(env_file_path "$name")"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    for entry in "$@"; do
      key="${entry%%=*}"
      msg "${DIM}would store ${key} in ${path}${RESET}"
    done
    return 0
  fi
  install -d -m 0700 "${ENV_DIR}"
  old_umask="$(umask)"
  umask 077
  : > "$path"
  for entry in "$@"; do
    if [[ "$entry" == *$'\n'* ]]; then die "credential values must be single lines"; fi
    printf '%s\n' "$entry" >> "$path"
  done
  chmod 0600 "$path"
  umask "$old_umask"
  ok "stored credentials in ${path}"
}

# --- specs ------------------------------------------------------------------

C_NAME=()
C_AGENT=()
C_MODE=()
C_WORKSPACE=()

add_spec() {
  C_NAME+=("$1"); C_AGENT+=("$2"); C_MODE+=("$3"); C_WORKSPACE+=("$4")
}

show_specs() {
  local i
  if [[ "${#C_NAME[@]}" -eq 0 ]]; then msg "  (nothing)"; return 0; fi
  printf '%-24s %-12s %-11s %s\n' NAME AGENT MODE WORKSPACE
  for ((i = 0; i < ${#C_NAME[@]}; i++)); do
    printf '%-24s %-12s %-11s %s\n' "${C_NAME[i]}" "${C_AGENT[i]}" "${C_MODE[i]}" "${C_WORKSPACE[i]}"
  done
}

parse_declaration() {
  local src="$1" line name agent mode workspace
  if [[ "$src" == "-" ]]; then
    exec 3<&0
  else
    [[ -r "$src" ]] || die "cannot read declaration file: $src"
    exec 3<"$src"
  fi
  while IFS= read -r line <&3 || [[ -n "$line" ]]; do
    line="${line%%#*}"
    # shellcheck disable=SC2086 # declaration files are whitespace separated
    set -- $line
    if [[ $# -eq 0 ]]; then continue; fi
    if [[ $# -lt 2 || $# -gt 4 ]]; then
      die "cannot parse '$line': expected 'name agent [mode] [workspace]'"
    fi
    name="$1"; agent="$2"; mode="${3:-persistent}"; workspace="${4:-}"
    if [[ -z "$workspace" ]]; then workspace="$(default_workspace "$name")"; fi
    validate_name "$name"
    validate_mode "$mode"
    if ! agent_index "$agent" >/dev/null; then
      die "unknown agent '$agent' in the declaration (image offers: ${AGENT_NAMES[*]})"
    fi
    add_spec "$name" "$agent" "$mode" "$workspace"
  done
  exec 3<&-
}

bulk_specs() {
  local count="${OPT_COUNT:-1}" agent mode workspace i name base idx
  agent="${OPT_AGENT:-${AGENT_NAMES[0]}}"
  mode="${OPT_MODE:-persistent}"
  idx="$(agent_index "$agent")" || die "unknown agent '$agent' (image offers: ${AGENT_NAMES[*]})"
  : "$idx"
  validate_mode "$mode"
  if [[ ! "$count" =~ ^[0-9]+$ ]] || (( count < 1 )); then die "--count needs a positive number"; fi
  base="${OPT_NAME:-}"
  if [[ -z "$base" ]]; then base="agent-workspace-${agent}"; fi
  validate_name "$base"
  for ((i = 1; i <= count; i++)); do
    if (( i == 1 )); then name="$base"; else name="${base}-${i}"; fi
    workspace="${OPT_WORKSPACE}"
    if [[ -z "$workspace" ]]; then workspace="$(default_workspace "$name")"; fi
    add_spec "$name" "$agent" "$mode" "$workspace"
  done
}

# --- wizard -----------------------------------------------------------------

prompt() {
  local question="$1" default="${2:-}" answer
  if [[ -n "$default" ]]; then printf '%s [%s]: ' "$question" "$default" >&2; else printf '%s: ' "$question" >&2; fi
  read -r answer || die "input closed before the wizard finished"
  if [[ -z "$answer" ]]; then printf '%s' "$default"; else printf '%s' "$answer"; fi
}

prompt_secret() {
  local question="$1" answer
  printf '%s: ' "$question" >&2
  read -r -s answer || die "input closed before the wizard finished"
  printf '\n' >&2
  printf '%s' "$answer"
}

prompt_choice() {
  local question="$1" default="$2" answer i
  shift 2
  local -a choices=("$@")
  printf '%s\n' "$question" >&2
  for ((i = 0; i < ${#choices[@]}; i++)); do
    printf '  %d) %s\n' "$((i + 1))" "${choices[i]}" >&2
  done
  printf 'choice [%s]: ' "$default" >&2
  read -r answer || die "input closed before the wizard finished"
  if [[ -z "$answer" ]]; then printf '%s' "$default"; return 0; fi
  if [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= ${#choices[@]} )); then
    printf '%s' "${choices[answer-1]}"
    return 0
  fi
  printf '%s' "$answer"
}

interactive_wizard() {
  local count i agent name mode workspace key value default_name idx
  local -a agent_vars=()

  heading "agent-workspace installer"
  msg "image:  ${IMAGE}"
  msg "agents: ${AGENT_NAMES[*]}"
  msg "a persistent container keeps running and is entered with podman exec;"
  msg "an ephemeral container serves one agent session and is then removed."

  count="$(prompt 'How many containers do you want to create' "${OPT_COUNT:-1}")"
  if [[ ! "$count" =~ ^[0-9]+$ ]] || (( count < 1 )); then die "not a number of containers: $count"; fi

  for ((i = 1; i <= count; i++)); do
    heading "Container ${i} of ${count}"
    agent="$(prompt_choice 'Which agent should it run' "${AGENT_NAMES[0]}" "${AGENT_NAMES[@]}")"
    idx="$(agent_index "$agent")" || die "unknown agent '$agent' (image offers: ${AGENT_NAMES[*]})"
    default_name="${agent}-box"
    if (( i > 1 )); then default_name="${agent}-box-${i}"; fi
    name="$(prompt 'Container name' "$default_name")"
    validate_name "$name"
    mode="$(prompt_choice 'How should it run' persistent persistent ephemeral)"
    validate_mode "$mode"
    if [[ -n "${OPT_WORKSPACE}" ]]; then
      workspace="${OPT_WORKSPACE}"
    else
      workspace="$(prompt 'Host directory to mount at /workspace' "$(default_workspace "$name")")"
    fi
    add_spec "$name" "$agent" "$mode" "$workspace"

    if [[ -n "${AGENT_ENVS[idx]:-}" ]]; then
      read -r -a agent_vars <<< "${AGENT_ENVS[idx]}"
      for key in "${agent_vars[@]}"; do
        if [[ -n "${SECRETS[$key]:-}" ]]; then continue; fi
        if [[ -n "${!key}" ]]; then
          SECRETS[$key]="${!key}"
          ok "${key} taken from this shell's environment"
          continue
        fi
        value="$(prompt_secret "${key} for ${name} (empty to skip)")"
        if [[ -n "$value" ]]; then SECRETS[$key]="$value"; ok "stored ${key}"; fi
      done
    fi
  done

  heading "Summary"
  show_specs
  if [[ "${ASSUME_YES}" -ne 1 ]]; then
    confirm "Create these containers" || die "aborted"
  fi
}

# --- podman -----------------------------------------------------------------

run_podman() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    printf '%s%s%s' "$DIM" "$PODMAN" "$RESET"
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$PODMAN" "$@"
}

require_podman() {
  if ! have_cmd "${PODMAN}" && [[ ! -x "${PODMAN}" ]]; then
    die "podman is required but '$PODMAN' was not found (set PODMAN=/path/to/podman)"
  fi
}

container_exists() { "$PODMAN" container exists "$1" >/dev/null 2>&1; }

volume_exists() { "$PODMAN" volume exists "$1" >/dev/null 2>&1; }

ensure_image() {
  if "$PODMAN" image exists "$IMAGE" >/dev/null 2>&1; then return 0; fi
  if [[ "${NO_PULL}" -eq 1 ]]; then die "image ${IMAGE} is not present locally and --no-pull was given"; fi
  if [[ "${DRY_RUN}" -eq 1 ]]; then msg "${DIM}would pull ${IMAGE}${RESET}"; return 0; fi
  heading "Pulling ${IMAGE}"
  run_podman pull "$IMAGE"
}

# --- create / remove / list / verify ----------------------------------------

create_container() {
  local name="$1" agent="$2" mode="$3" workspace="$4"
  local idx binary envfile entry key title
  local -a vars=() entries=() args=() fallback=()
  idx="$(agent_index "$agent")" || die "unknown agent '$agent'"
  binary="${AGENT_BINS[idx]}"
  title="${AGENT_TITLES[idx]}"

  if container_exists "$name"; then
    if [[ "${REPLACE}" -eq 1 ]]; then
      heading "Replacing ${name}"
      remove_container "$name"
    else
      die "container '${name}' already exists (pass --replace to recreate it)"
    fi
  fi

  if [[ -n "${AGENT_ENVS[idx]:-}" ]]; then
    read -r -a vars <<< "${AGENT_ENVS[idx]}"
  fi
  for key in "${vars[@]:-}"; do
    if [[ -z "$key" ]]; then continue; fi
    if [[ -n "${SECRETS[$key]:-}" ]]; then entries+=("${key}=${SECRETS[$key]}"); fi
  done
  for entry in "${EXTRA_ENVS[@]:-}"; do
    if [[ -n "$entry" ]]; then entries+=("$entry"); fi
  done

  envfile="$(env_file_path "$name")"
  if [[ "${DRY_RUN}" -eq 0 ]]; then mkdir -p -- "$workspace"; fi
  if [[ "${#entries[@]}" -gt 0 ]]; then write_env_file "$name" "${entries[@]}"; fi

  args=(run)
  if [[ "$mode" == persistent ]]; then
    args+=(--detach --restart unless-stopped --systemd=always)
    args+=(--volume "${VOLUME_PREFIX}-${name}-home:/home/agent")
  else
    args+=(--rm --interactive --tty)
  fi
  args+=(--name "$name" --hostname "$name")
  args+=(--label "${LABEL_KEY}=${LABEL_VALUE}")
  args+=(--label "agent-workspace.agent=$agent")
  args+=(--label "agent-workspace.mode=$mode")
  args+=(--volume "${workspace}:/workspace:z" --workdir /workspace)
  args+=(--env "AGENT_WORKSPACE_AGENT=$agent")
  if [[ "${#entries[@]}" -gt 0 ]]; then args+=(--env-file "$envfile"); fi
  for entry in "${EXTRA_ARGS[@]:-}"; do
    if [[ -n "$entry" ]]; then args+=("$entry"); fi
  done
  args+=("$IMAGE")
  if [[ "$mode" != persistent ]]; then args+=("$binary"); fi

  heading "Creating ${name} (${agent} / ${mode})"
  if [[ "$mode" == persistent ]]; then
    if ! run_podman "${args[@]}"; then
      warn "podman could not boot systemd in ${name}; retrying it as a keep-alive container"
      run_podman rm --force "$name" >/dev/null 2>&1 || true
      fallback=(run --detach --restart unless-stopped --name "$name" --hostname "$name")
      fallback+=(--label "${LABEL_KEY}=${LABEL_VALUE}")
      fallback+=(--label "agent-workspace.agent=$agent" --label "agent-workspace.mode=$mode")
      fallback+=(--volume "${workspace}:/workspace:z" --volume "${VOLUME_PREFIX}-${name}-home:/home/agent")
      fallback+=(--env "AGENT_WORKSPACE_AGENT=$agent")
      if [[ "${#entries[@]}" -gt 0 ]]; then fallback+=(--env-file "$envfile"); fi
      for entry in "${EXTRA_ARGS[@]:-}"; do
        if [[ -n "$entry" ]]; then fallback+=("$entry"); fi
      done
      fallback+=(--entrypoint /bin/sleep "$IMAGE" inf)
      run_podman "${fallback[@]}"
      warn "${name} is a keep-alive container without systemd; start the agent with 'podman exec -it ${name} ${binary}'"
    fi
  else
    run_podman "${args[@]}"
  fi
  ok "${name} created (${title})"
}

remove_container() {
  local name="$1" envfile volume
  envfile="$(env_file_path "$name")"
  volume="${VOLUME_PREFIX}-${name}-home"
  if container_exists "$name"; then
    run_podman rm --force "$name"
    ok "removed container ${name}"
  else
    warn "no container named '${name}'"
  fi
  if volume_exists "$volume"; then
    run_podman volume rm "$volume"
    ok "removed volume ${volume}"
  fi
  if [[ -f "$envfile" ]]; then
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      msg "${DIM}would delete ${envfile}${RESET}"
    else
      rm -f -- "$envfile"
      ok "removed ${envfile}"
    fi
  fi
}

list_containers() {
  local out name status agent mode
  heading "agent-workspace containers"
  out="$("$PODMAN" ps --all --filter "label=${LABEL_KEY}=${LABEL_VALUE}" --format '{{.Names}}\t{{.Status}}' 2>/dev/null || true)"
  if [[ -z "$out" ]]; then
    msg "  none yet -- run ./${PROG} to create one"
    return 0
  fi
  printf '%-24s %-12s %-11s %s\n' NAME AGENT MODE STATUS
  while IFS=$'\t' read -r name status; do
    if [[ -z "$name" ]]; then continue; fi
    agent="$("$PODMAN" inspect --format '{{index .Config.Labels "agent-workspace.agent"}}' "$name" 2>/dev/null || true)"
    mode="$("$PODMAN" inspect --format '{{index .Config.Labels "agent-workspace.mode"}}' "$name" 2>/dev/null || true)"
    printf '%-24s %-12s %-11s %s\n' "$name" "${agent:-?}" "${mode:-?}" "$status"
  done <<< "$out"
}

verify_containers() {
  local out name agent mode binary state failures=0
  heading "Verifying agent-workspace containers"
  out="$("$PODMAN" ps --all --filter "label=${LABEL_KEY}=${LABEL_VALUE}" --format '{{.Names}}' 2>/dev/null || true)"
  if [[ -z "$out" ]]; then
    warn "no containers to verify"
    return 0
  fi
  while IFS= read -r name; do
    if [[ -z "$name" ]]; then continue; fi
    agent="$("$PODMAN" inspect --format '{{index .Config.Labels "agent-workspace.agent"}}' "$name" 2>/dev/null || true)"
    mode="$("$PODMAN" inspect --format '{{index .Config.Labels "agent-workspace.mode"}}' "$name" 2>/dev/null || true)"
    state="$("$PODMAN" inspect --format '{{.State.Status}}' "$name" 2>/dev/null || true)"
    binary="$(agent_binary_of "${agent:-}")"
    if [[ "$mode" == persistent ]]; then
      if [[ "$state" == running ]]; then
        ok "${name} is running"
      else
        warn "${name} is ${state:-unknown} (expected running)"
        failures=$((failures + 1))
      fi
      if [[ -n "$binary" ]]; then
        if "$PODMAN" exec "$name" bash -lc "command -v ${binary}" >/dev/null 2>&1; then
          ok "${name} can run ${binary}"
        else
          warn "${name} does not have ${binary} on PATH"
          failures=$((failures + 1))
        fi
      fi
    else
      ok "${name} is a one-shot container (nothing to check while it is not running)"
    fi
  done <<< "$out"
  if (( failures > 0 )); then die "${failures} check(s) failed"; fi
  ok "all containers look healthy"
}

print_hints() {
  local i name agent mode binary workspace
  heading "Done"
  for ((i = 0; i < ${#C_NAME[@]}; i++)); do
    name="${C_NAME[i]}"; agent="${C_AGENT[i]}"; mode="${C_MODE[i]}"; workspace="${C_WORKSPACE[i]}"
    binary="$(agent_binary_of "$agent")"
    if [[ "$mode" == persistent ]]; then
      msg "  ${name} (persistent)"
      msg "    podman exec -it ${name} ${binary}    # run the agent"
      msg "    podman exec -it ${name} bash         # shell inside the sandbox"
      msg "    ./${PROG} --remove ${name}           # delete it again"
    else
      msg "  ${name} (ephemeral), recreate a session with"
      msg "    podman run --rm -it --volume \"${workspace}:/workspace:z\" --workdir /workspace ${IMAGE} ${binary}"
    fi
  done
}

# --- argument parsing -------------------------------------------------------

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --file) DECL_FILE="${2:-}"; shift 2 ;;
      --save) SAVE_FILE="${2:-}"; shift 2 ;;
      --image) IMAGE="${2:-}"; shift 2 ;;
      --agent) OPT_AGENT="${2:-}"; shift 2 ;;
      --name) OPT_NAME="${2:-}"; shift 2 ;;
      --count) OPT_COUNT="${2:-}"; shift 2 ;;
      --mode) OPT_MODE="${2:-}"; shift 2 ;;
      --workspace) OPT_WORKSPACE="${2:-}"; shift 2 ;;
      --env) EXTRA_ENVS+=("${2:-}"); shift 2 ;;
      --extra-arg) EXTRA_ARGS+=("${2:-}"); shift 2 ;;
      --list) ACTION="list"; shift ;;
      --verify) ACTION="verify"; shift ;;
      --remove) ACTION="remove"; OPT_NAME="${2:-}"; shift 2 ;;
      --dry-run|-n) DRY_RUN=1; shift ;;
      --no-pull) NO_PULL=1; shift ;;
      --replace) REPLACE=1; shift ;;
      --yes|-y) ASSUME_YES=1; shift ;;
      --quiet) QUIET=1; shift ;;
      --help|-h) ACTION="help"; shift ;;
      --) shift ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
  done
  if [[ "${ACTION}" == "remove" && -z "${OPT_NAME}" ]]; then die "--remove needs a container name"; fi
  if [[ "${ACTION}" != "" && -n "${DECL_FILE}" ]]; then die "--${ACTION} cannot be combined with --file"; fi
}

save_declaration() {
  local file="$1" i stamp
  if [[ "${DRY_RUN}" -eq 1 ]]; then msg "${DIM}would write ${file}${RESET}"; return 0; fi
  stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p -- "$(dirname -- "$file")"
  {
    printf '# agent-workspace containers, written by %s on %s\n' "$PROG" "$stamp"
    printf '# name\tagent\tmode\tworkspace\n'
    for ((i = 0; i < ${#C_NAME[@]}; i++)); do
      printf '%s\t%s\t%s\t%s\n' "${C_NAME[i]}" "${C_AGENT[i]}" "${C_MODE[i]}" "${C_WORKSPACE[i]}"
    done
  } > "$file"
  ok "wrote ${file}"
}

main() {
  if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then die "bash 4 or newer is required"; fi
  parse_args "$@"

  case "${ACTION}" in
    help) usage; return 0 ;;
    list)
      require_podman
      list_containers
      return 0
      ;;
    remove)
      require_podman
      if [[ "${ASSUME_YES}" -ne 1 ]]; then
        confirm "Delete container ${OPT_NAME} with its home volume" || die "aborted"
      fi
      remove_container "${OPT_NAME}"
      return 0
      ;;
    verify)
      require_podman
      if [[ -z "${IMAGE}" ]]; then IMAGE="$(default_image)"; fi
      load_agents
      verify_containers
      return 0
      ;;
  esac

  require_podman
  if [[ -z "${IMAGE}" ]]; then IMAGE="$(default_image)"; fi
  ensure_image
  load_agents

  if [[ -n "${DECL_FILE}" ]]; then
    parse_declaration "${DECL_FILE}"
    collect_ambient_secrets "${C_AGENT[0]}"
    heading "Summary"
    show_specs
  elif [[ -n "${OPT_AGENT}" ]]; then
    collect_ambient_secrets "${OPT_AGENT}"
    bulk_specs
    heading "Summary"
    show_specs
  elif [[ -t 0 && -z "${OPT_COUNT}" && -z "${OPT_NAME}" ]]; then
    interactive_wizard
  else
    die "nothing to do: pass --file, or --agent, or run this from a terminal"
  fi

  if [[ -t 0 && "${ASSUME_YES}" -ne 1 && -z "${DECL_FILE}" && -z "${OPT_AGENT}" ]]; then
    : # the wizard asked for confirmation already
  fi
  if [[ -n "${DECL_FILE}" || -n "${OPT_AGENT}" ]]; then
    if [[ "${ASSUME_YES}" -ne 1 ]]; then
      confirm "Create these containers" || die "aborted"
    fi
  fi

  local i
  for ((i = 0; i < ${#C_NAME[@]}; i++)); do
    create_container "${C_NAME[i]}" "${C_AGENT[i]}" "${C_MODE[i]}" "${C_WORKSPACE[i]}"
  done
  if [[ -n "${SAVE_FILE}" ]]; then save_declaration "${SAVE_FILE}"; fi
  print_hints
}

main "$@"
