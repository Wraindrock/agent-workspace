#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# A fake container engine used by tests/install.sh.
#
# It understands the subset of podman/docker that install.sh uses and keeps
# its "state" in $FAKE_ENGINE_STATE, so the whole installer can be exercised
# without root, an engine or a network.
#
#   containers/<name>/state   running | stopped | gone
#   containers/<name>/image   the image the container was created from
#   volumes/<name>/marker     optional marker describing copied data
#   images/<sanitised ref>    presence means the image is local
#   log                       every invocation, one per line
# ---------------------------------------------------------------------------
set -uo pipefail

ENGINE_NAME="${FAKE_ENGINE_NAME:-podman}"
STATE="${FAKE_ENGINE_STATE:?FAKE_ENGINE_STATE must be set}"
mkdir -p "$STATE/containers" "$STATE/volumes" "$STATE/images"
printf '%s %s\n' "$ENGINE_NAME" "$*" >>"$STATE/log"

sanitise() { printf '%s' "$1" | tr '/:' '__'; }
container_dir() { printf '%s/containers/%s' "$STATE" "$1"; }
volume_dir() { printf '%s/volumes/%s' "$STATE" "$1"; }
image_file() { printf '%s/images/%s' "$STATE" "$(sanitise "$1")"; }

has_container() { [[ -f "$(container_dir "$1")/state" ]]; }
container_state() { cat "$(container_dir "$1")/state" 2>/dev/null || printf 'gone'; }
has_volume() { [[ -d "$(volume_dir "$1")" ]]; }
has_image() { [[ -f "$(image_file "$1")" ]]; }

# like a real engine, an image a container was created from is still "in use"
image_in_use() {
  local ref="$1" sdir
  for sdir in "$STATE"/containers/*/state; do
    [[ -f "$sdir" ]] || continue
    [[ "$(cat "$sdir")" == "gone" ]] && continue
    [[ "$(cat "$(dirname "$sdir")/image" 2>/dev/null)" == "$ref" ]] && return 0
  done
  return 1
}

# host_dir_for TARGET prints the host directory mounted at TARGET
host_dir_for() {
  local target="$1" entry
  while read -r entry; do
    case "$entry" in
      *:"$target":*) printf '%s' "${entry%%:*}"; return 0 ;;
      *:"$target")   printf '%s' "${entry%%:*}"; return 0 ;;
    esac
  done <<<"${FAKE_MOUNTS:-}"
  return 1
}

cmd="${1:-}"
shift || true

case "$cmd" in
  --version)
    if [[ "$ENGINE_NAME" == "podman" ]]; then printf 'podman version 5.0.0-fake\n'; else printf 'Docker version 27.0.0-fake, build fake\n'; fi
    exit 0
    ;;
  container)
    case "${1:-}" in
      inspect)
        has_container "${2:-}" && { printf '{}\n'; exit 0; }
        printf 'Error: no such container\n' >&2
        exit 1
        ;;
      *) exit 0 ;;
    esac
    ;;
  inspect)
    fmt=""; name=""
    while [[ "$#" -gt 0 ]]; do
      case "$1" in
        --format) fmt="$2"; shift 2 ;;
        *) name="$1"; shift ;;
      esac
    done
    has_container "$name" || { printf 'Error: no such container\n' >&2; exit 1; }
    case "$fmt" in
      *State.Running*) [[ "$(container_state "$name")" == "running" ]] && printf 'true\n' || printf 'false\n' ;;
      *State.Status*)  container_state "$name"; printf '\n' ;;
      *Config.Image*)  cat "$(container_dir "$name")/image"; printf '\n' ;;
      *) printf '{}\n' ;;
    esac
    exit 0
    ;;
  ps)
    filter=""
    while [[ "$#" -gt 0 ]]; do
      case "$1" in
        --filter) filter="$2"; shift 2 ;;
        --format|--all) shift ;;
        --format=*) shift ;;
        *) shift ;;
      esac
    done
    # only label filters matter to install.sh: label=<key>=<value>
    filter="${filter#label=}"
    for dir in "$STATE"/containers/*/state; do
      [[ -f "$dir" ]] || continue
      [[ "$(cat "$dir")" == "gone" ]] && continue
      cname="$(basename "$(dirname "$dir")")"
      if [[ -n "$filter" ]]; then
        grep -qxF "$filter" "$(dirname "$dir")/labels" 2>/dev/null || continue
      fi
      printf '%s\n' "$cname"
    done
    exit 0
    ;;
  volume)
    case "${1:-}" in
      inspect) has_volume "${2:-}" && { printf '{}\n'; exit 0; }; printf 'no such volume\n' >&2; exit 1 ;;
      create) mkdir -p "$(volume_dir "${2:-}")"; printf '%s\n' "${2:-}"; exit 0 ;;
      rm)
        for arg in "$@"; do [[ "$arg" == -* ]] || rm -rf "$(volume_dir "$arg")"; done
        exit 0
        ;;
      *) exit 0 ;;
    esac
    ;;
  image)
    case "${1:-}" in
      inspect) has_image "${2:-}" && { printf '{}\n'; exit 0; }; printf 'no such image\n' >&2; exit 1 ;;
      *) exit 0 ;;
    esac
    ;;
  pull)
    ref="${1:-}"
    tag=latest
    case "$ref" in *:*) tag="${ref##*:}" ;; esac
    : >"$(image_file "$ref")"
    printf 'pulled %s (tag %s)\n' "$ref" "$tag"
    exit 0
    ;;
  run)
    name=""; entrypoint=""; rm_flag=0; interactive=0; image=""; env_file=""; publish=""
    FAKE_MOUNTS=""
    command_args=()
    labels=()
    while [[ "$#" -gt 0 ]]; do
      case "$1" in
        --name) name="$2"; shift 2 ;;
        --entrypoint) entrypoint="$2"; shift 2 ;;
        --rm) rm_flag=1; shift ;;
        --interactive|--tty|-i|-t) interactive=1; shift ;;
        --volume|-v)
          # translate named volumes into their host directories so tar/cp plumbing
          # touches real files, exactly like a real engine would
          IFS=':' read -r v_src v_dst v_opts <<<"$2"
          if [[ "$v_src" != /* ]]; then
            v_src="$(volume_dir "$v_src")"
            mkdir -p "$v_src"
          fi
          if [[ -n "${v_opts:-}" ]]; then
            FAKE_MOUNTS="${FAKE_MOUNTS}${v_src}:${v_dst}:${v_opts}"$'\n'
          else
            FAKE_MOUNTS="${FAKE_MOUNTS}${v_src}:${v_dst}"$'\n'
          fi
          shift 2
          ;;
        --detach|-d|--privileged) shift ;;
        --publish|-p) publish="$2"; shift 2 ;;
        --env-file) env_file="$2"; shift 2 ;;
        --label) labels+=("$2"); shift 2 ;;
        --env|--hostname|--workdir|--restart|--systemd|--cgroupns|--tmpfs) shift 2 ;;
        -*) shift ;;
        *)
          # the first bare argument is the image; everything after it is the command
          if [[ -z "$image" ]]; then image="$1"; else command_args+=("$1"); fi
          shift
          ;;
      esac
    done

    if [[ -n "$entrypoint" ]]; then
      # a helper container: tar or bash based volume plumbing
      case "$entrypoint" in
        */tar)
          # Real tar, so snapshot archives are genuine tarballs and doctor's
          # "tar -tzf" check means something.
          case "${command_args[*]:-}" in
            czf*)
              target="$(host_dir_for /backup || true)"
              data="$(host_dir_for /data || true)"
              [[ -n "$target" ]] || { printf 'no backup mount\n' >&2; exit 1; }
              [[ -n "$data" ]] || { printf 'no data mount\n' >&2; exit 1; }
              if [[ "${FAKE_ENGINE_BAD_ARCHIVE:-0}" == "1" ]]; then
                # a write that "succeeds" but leaves an unreadable archive
                printf 'not a tarball\n' >"${target}/home.tar.gz"
              else
                tar czf "${target}/home.tar.gz" -C "$data" .
              fi
              exit 0
              ;;
            xzf*)
              src="$(host_dir_for /backup || true)"
              dest="$(host_dir_for /data || true)"
              [[ -n "$src" && -f "${src}/home.tar.gz" ]] || { printf 'no archive\n' >&2; exit 1; }
              [[ -n "$dest" ]] || { printf 'no data mount\n' >&2; exit 1; }
              tar xzf "${src}/home.tar.gz" -C "$dest"
              : >"${dest}/restored"
              exit 0
              ;;
          esac
          exit 0
          ;;
        */bash|*/sh)
          from="$(host_dir_for /from || true)"
          to="$(host_dir_for /to || true)"
          [[ -n "$from" && -n "$to" ]] || { printf 'bad mounts\n' >&2; exit 1; }
          cp -a "${from}/." "${to}/" 2>/dev/null || true
          : >"${to}/copied-from"
          exit 0
          ;;
      esac
      exit 0
    fi

    if [[ "$rm_flag" -eq 1 ]]; then
      printf 'fake ephemeral run (tty=%s): %s\n' "$interactive" "${command_args[*]:-}" >>"$STATE/log"
      exit 0
    fi

    [[ -n "$name" ]] || { printf 'fake run without --name\n' >&2; exit 1; }
    dir="$(container_dir "$name")"
    mkdir -p "$dir"
    printf 'running\n' >"${dir}/state"
    printf '%s\n' "${image:-unknown}" >"${dir}/image"
    # remember the credentials the container was started with
    if [[ -n "${env_file:-}" && -f "$env_file" ]]; then cp "$env_file" "${dir}/env"; fi
    # remember labels so "ps --filter label=..." behaves like the real engine
    if [[ "${#labels[@]}" -gt 0 ]]; then printf '%s\n' "${labels[@]}" >"${dir}/labels"; fi
    # remember published ports so "port" can resolve them like a real engine
    if [[ -n "$publish" ]]; then printf '%s\n' "$publish" >"${dir}/publish"; fi
    printf '%s\n' "$name"
    exit 0
    ;;
  commit)
    args=()
    while [[ "$#" -gt 0 ]]; do
      case "$1" in
        --format) shift 2 ;;
        *) args+=("$1"); shift ;;
      esac
    done
    src="${args[0]:-}"; ref="${args[1]:-}"
    has_container "$src" || { printf 'no such container\n' >&2; exit 1; }
    : >"$(image_file "$ref")"
    printf 'sha256-fake-%s\n' "${ref//[^A-Za-z0-9]/}"
    exit 0
    ;;
  rmi)
    force=0
    refs=()
    for arg in "$@"; do
      case "$arg" in
        --force|-f) force=1 ;;
        -*) ;;
        *) refs+=("$arg") ;;
      esac
    done
    for ref in "${refs[@]:-}"; do
      [[ -n "$ref" ]] || continue
      if [[ "$force" -eq 0 ]] && image_in_use "$ref"; then
        printf 'Error: image %s is in use by a container\n' "$ref" >&2
        exit 1
      fi
      rm -f "$(image_file "$ref")"
    done
    exit 0
    ;;
  rm)
    for arg in "$@"; do
      [[ "$arg" == -* ]] && continue
      rm -rf "$(container_dir "$arg")"
    done
    exit 0
    ;;
  stop)
    [[ -n "${1:-}" ]] && printf 'stopped\n' >"$(container_dir "$1")/state"
    exit 0
    ;;
  start)
    [[ -n "${1:-}" ]] || exit 1
    if has_container "$1"; then printf 'running\n' >"$(container_dir "$1")/state"; exit 0; fi
    printf 'no such container\n' >&2
    exit 1
    ;;
  port)
    # port NAME PORT[/tcp] resolves a published port to its host address
    name="${1:-}"; req="${2:-}"; req="${req%%/*}"
    dir="$(container_dir "$name")"
    if [[ -f "${dir}/publish" ]]; then
      IFS=':' read -r p_host p_hostport p_container <<<"$(cat "${dir}/publish")"
      if [[ "${p_container:-}" == "$req" ]]; then printf '%s:%s\n' "${p_host:-127.0.0.1}" "$p_hostport"; exit 0; fi
    fi
    printf 'no such published port\n' >&2
    exit 1
    ;;
  exec)
    printf 'fake exec: %s\n' "$*" >>"$STATE/log"
    name=""; script=""
    while [[ "$#" -gt 0 ]]; do
      case "$1" in
        --user|--env|--workdir) shift 2 ;;
        -*) shift ;;
        *) if [[ -z "$name" ]]; then name="$1"; else script="$1"; fi; shift ;;
      esac
    done
    dir="$(container_dir "$name")"
    case "$script" in
      *grep\ -o*)
        [[ -f "${dir}/webtoken" ]] && cat "${dir}/webtoken"
        exit 0
        ;;
      */dev/tcp/*)
        # the installer probes the port this way to see whether the UI is up
        [[ -f "${dir}/webtoken" ]] && exit 0
        exit 1
        ;;
      *dsh\ web*)
        printf 'dsh web: http://127.0.0.1:3080/?token=faketok3n\n' >"${dir}/webtoken"
        exit 0
        ;;
    esac
    exit 0
    ;;
  logs)
    printf 'fake logs for %s\n' "$*"
    exit 0
    ;;
  *)
    printf 'fake engine: unhandled command: %s\n' "$cmd" >>"$STATE/log"
    exit 0
    ;;
esac
