#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Backend abstraction: one interface over every way this installer can run a
# workspace.
#
# A backend is a name (podman, docker, incus, kvm) plus an implementation file,
# installer/lib/backend-<name>.sh, that defines the same set of verbs:
#
#   eng_version                 the backend's own version line
#   eng_container_exists        does an instance by this name exist
#   eng_container_running       1 when it is running
#   eng_container_status        running/exited/... or "missing"
#   eng_container_image         the image the instance was created from
#   eng_labeled_containers      every instance carrying our labels
#   eng_volume_exists           is the backing home volume there
#   eng_image_exists            is the image present locally
#   eng_image_id                short id of the local image (display only)
#   eng_image_created           build time of the local image (display only)
#   eng_host_port               host address a published port is bound to
#   eng_pull                    fetch an image
#   eng_image_remove            drop a local image
#   eng_image_run               run a one-shot command out of an image
#   eng_create_persistent       create the long-lived workspace instance
#   eng_create_ephemeral        create the one-shot instance
#   eng_start / eng_stop        start, stop
#   eng_remove                  delete the instance (and nothing else)
#   eng_volume_create / eng_volume_remove
#   eng_exec                    interactive shell command in the instance
#   eng_exec_root               interactive root shell command (rescue)
#   eng_exec_nofail             non-interactive command, status discarded
#   eng_volume_archive          archive a home volume into DIR/home.tar.gz
#   eng_volume_restore_archive  extract such an archive into a volume
#   eng_volume_clone            copy one home volume into another
#   eng_volume_export_path      copy one path out of a volume (rescue --copy)
#   eng_logs                    the instance's console log
#   eng_commit                  freeze a running instance into an image
#
# The installer never branches on the backend's *name*: it calls a verb. What a
# backend cannot do it does the long way round - Incus, for instance, has no
# native snapshot for a workspace whose home is a host directory, so it uses the
# same commit + home-archive path as every other backend. `ENGINE` holds the active
# backend's name and doubles as the on-disk state key; `ENGINE_BIN` is the
# command it drives.
# ---------------------------------------------------------------------------

ENGINE="${ENGINE:-}"
ENGINE_BIN="${ENGINE_BIN:-}"
# Empty means "the user did not pass --backend". It is deliberately NOT "auto":
# there is no automatic backend choice (docs/backend-model.md, "Backend
# selection: no auto"). The remembered choice (state_backend_pref) is consulted
# only when this is empty, and a non-interactive run with no remembered choice
# fails instead of picking one.
BACKEND_REQUEST="${BACKEND_REQUEST:-}"
BACKEND_DIR="${BACKEND_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# Backends that are implemented but deliberately not selectable in this
# version. A gate rather than a deletion (docs/backend-model.md, "Incus:
# visible, not hidden, not selectable"): backend-incus.sh stays in the tree, in
# the list, in the help and under test; only the selection is refused. One
# flag turns it back on for a host that can actually run it.
BACKEND_GATED="${BACKEND_GATED:-incus}"
AW_ENABLE_BACKEND_INCUS="${AW_ENABLE_BACKEND_INCUS:-0}"
# Still the mechanism for a backend that is described but not driven (a future
# backend can be added to this list without touching the selection code). It is
# empty today: every backend in the table now has an implementation file. KVM
# left this list with backend-kvm.sh - a bootable qcow2/rootfs is implemented;
# see docs/backend-model.md.
BACKEND_UNIMPLEMENTED="${BACKEND_UNIMPLEMENTED:-}"

# KVM settings shared by the probe (this file) and backend-kvm.sh. They live
# here because backend_ready runs before a backend file is loaded: the list and
# the chooser must be able to answer "is kvm usable" without sourcing it.
KVM_URI="${KVM_URI:-${AW_KVM_URI:-qemu:///session}}"
# tests set AW_KVM_DEVICE to a plain file: the probe must stay runnable on a CI
# machine without /dev/kvm, and a fake device tests the code around the check.
KVM_DEVICE="${KVM_DEVICE:-${AW_KVM_DEVICE:-/dev/kvm}}"
KVM_ROOT="${KVM_ROOT:-${AW_KVM_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/agent-workspace/vms}}"

# backend_bin NAME prints the command a backend drives. Every backend is named
# after its binary except kvm, whose implementation drives virsh: a host does not
# have a `kvm` command, and probing for one would report the backend missing on a
# perfectly capable host.
backend_bin() {
  case "${1:-}" in
    kvm) printf 'virsh' ;;
    *)   printf '%s' "${1:-}" ;;
  esac
}

# kvm_probe checks everything backend-kvm.sh needs before it can boot anything,
# and records every missing item in KVM_PROBE_MISSING (one line, separators "; ")
# so the refusal can name them. Read-only: it never creates the storage
# directory, because the comparison table calls it on hosts that never asked for
# KVM. A missing binary short-circuits nothing: all missing items are collected.
kvm_probe() {
  local bin parent
  KVM_PROBE_MISSING=""
  if [[ ! -e "${KVM_DEVICE}" ]]; then
    KVM_PROBE_MISSING="${KVM_DEVICE} does not exist (nested virtualisation disabled?)"
  elif [[ ! -r "${KVM_DEVICE}" || ! -w "${KVM_DEVICE}" ]]; then
    KVM_PROBE_MISSING="${KVM_DEVICE} is not readable and writable (add the user to the kvm group)"
  fi
  for bin in virsh qemu-img virt-install xorriso mkfs.ext4 ssh ssh-keygen unshare; do
    if ! command -v "$bin" >/dev/null 2>&1; then
      _kvm_probe_missing "${bin} is not on PATH"
    fi
  done
  # The OCI image transport is podman/docker. Without one there is nothing to
  # export the image with, so refuse before downloading anything.
  if ! command -v podman >/dev/null 2>&1 && ! command -v docker >/dev/null 2>&1; then
    _kvm_probe_missing "podman or docker is not on PATH (it exports the OCI image)"
  fi
  # The disk image is assembled in an unprivileged user namespace so that the
  # root-owned file modes (setuid binaries included) survive the export. Without
  # it every rootfs file would keep the invoking user's ownership and sudo would
  # be broken inside the guest.
  if command -v unshare >/dev/null 2>&1 && ! unshare -r true >/dev/null 2>&1; then
    _kvm_probe_missing "unprivileged user namespaces are unavailable (unshare -r fails)"
  fi
  if command -v virsh >/dev/null 2>&1; then
    if ! virsh --connect "$KVM_URI" version >/dev/null 2>&1; then
      _kvm_probe_missing "libvirt is not reachable at ${KVM_URI} (sudo systemctl enable --now virtqemud.socket virtnetworkd.socket)"
    fi
  fi
  # Walk up to the first existing parent: the storage root itself is created on
  # first use, and probing must not leave directories behind on a host that only
  # asked for the comparison table.
  parent="${KVM_ROOT}"
  while [[ -n "${parent}" && ! -e "${parent}" ]]; do
    parent="$(dirname "${parent}")"
  done
  if [[ -z "${parent}" || ! -w "${parent}" ]]; then
    _kvm_probe_missing "storage directory ${KVM_ROOT} is not writable (AW_KVM_ROOT overrides it)"
  fi
  [[ -z "${KVM_PROBE_MISSING}" ]]
}

_kvm_probe_missing() {
  if [[ -z "${KVM_PROBE_MISSING}" ]]; then
    KVM_PROBE_MISSING="${1}"
  else
    KVM_PROBE_MISSING+="; ${1}"
  fi
}

# backend_version_line NAME prints the backend's own version line for doctor.
backend_version_line() {
  case "${1:-}" in
    kvm)
      virsh --connect "$KVM_URI" version 2>/dev/null \
        | sed -n 's/^Using library version /libvirt /p' | head -n 1 || true
      ;;
    *)
      "$(backend_bin "${1:-}")" --version 2>/dev/null | head -n 1 || true
      ;;
  esac
}

# backend_gated NAME: is NAME refused for now? The environment flag is the
# documented way to turn the gate off; a bare `0` (the default) keeps it on.
backend_gated() {
  local name="${1:-}"
  if [[ "$name" == "incus" && "${AW_ENABLE_BACKEND_INCUS:-0}" != "0" ]]; then
    return 1
  fi
  case ",${BACKEND_GATED}," in
    *",${name},"*) return 0 ;;
  esac
  return 1
}

# backend_unimplemented NAME: known from the design, not driven by this version.
backend_unimplemented() {
  case ",${BACKEND_UNIMPLEMENTED}," in
    *",${1:-},"*) return 0 ;;
  esac
  return 1
}

# backend_installable NAME: does this tree carry an implementation for NAME? The
# gate and the unimplemented list are about *selecting* a backend, not about
# whether the code exists, so they are checked where a choice is made
# (validate_backend and resolve_backend), never here: backend_names has to keep
# telling the truth about what is installed.
backend_installable() {
  local name="${1:-}"
  [[ -r "${BACKEND_DIR}/backend-${name}.sh" ]]
}

# backend_all_names prints every backend the model knows, in the order the
# comparison table lists them: the recommendation first, then the lighter
# container backends, then the one that is gated. Unlike backend_names this is
# not filtered by what is installed, because the user has to see the trade-offs
# of a backend they do not have yet.
backend_all_names() {
  printf '%s\n' kvm podman docker incus
}

# validate_backend NAME: is NAME one of the backends this model knows? The
# remembered choice and the command line both go through this, so a typo can
# never be stored and later resolved into something surprising.
validate_backend() {
  local name="${1:-}"
  [[ -n "$name" ]] || return 1
  case ",$(backend_all_names | paste -sd, -)," in
    *",${name},"*) return 0 ;;
  esac
  return 1
}

# backend_names prints every backend this installer can drive that is present on
# the host, in preference order. The gate is deliberately ignored here: a gated
# backend is still installed, still worth listing, and the incus tests use this
# to prove the gate is about selectability, not deletion. Selecting it is
# refused in validate_backend and resolve_backend. It only counts as *present*
# once backend-NAME.sh exists, so an incomplete tree never advertises a backend
# it cannot drive.
backend_names() {
  local name
  for name in kvm incus podman docker; do
    backend_installable "$name" || continue
    command -v "$(backend_bin "$name")" >/dev/null 2>&1 || continue
    printf '%s\n' "$name"
  done
  # A caller assigns this: `names="$(backend_names)"`. Without an explicit 0 the
  # function would inherit the status of the last command - a `command -v` that
  # found nothing for the last backend in the list - and the assignment would
  # then fail under `set -e`, killing every dry run on a host that has, say,
  # podman but not docker. Silence, exit 1, no message: exactly the failure that
  # took a bisect to find.
  return 0
}

# backend_ready NAME tells whether the backend can actually do work right now.
# A binary on PATH is not enough: an installed-but-uninitialised Incus answers
# every verb with an error, and silently picking it would turn "run a workspace"
# into a wall of failures. Read-only and never fatal.
backend_ready() {
  local name="${1:-}"
  command -v "$(backend_bin "$name")" >/dev/null 2>&1 || return 1
  case "$name" in
    kvm)   kvm_probe || return 1 ;;
    incus) "${name}" info >/dev/null 2>&1 || return 1 ;;
    *)     "${name}" --version >/dev/null 2>&1 || return 1 ;;
  esac
  return 0
}

# backend_not_ready_hint NAME prints the one action that would make the backend
# usable. Criterion for a good hint: the user can paste it. Nothing here is run
# by the installer - preparing the host is the user's call (see doctor).
backend_not_ready_hint() {
  case "${1:-}" in
    kvm)
      # kvm_probe recorded the exact list; the install command is the part a user
      # cannot guess. Package names differ per distribution, so both are offered.
      printf '%s (%s)' \
        "$(tf backend_hint_kvm_install)" \
        "${KVM_PROBE_MISSING:-$(tf backend_hint_kvm_missing)}"
      ;;
    incus) printf '%s\n' 'sudo systemctl enable --now incus.socket && sudo incus admin init --minimal' ;;
    *)     printf '%s\n' "the ${1} daemon is not answering" ;;
  esac
}

# backend_status_key NAME prints the catalogue key naming NAME's state on this
# host, plus the `available` fallback (plus: `awk -v x="$(...)"` would be the
# alternative, and it is less readable).
backend_status_key() {
  local name="${1:-}"
  if backend_unimplemented "$name"; then
    printf 'backend_unimplemented'
  elif backend_gated "$name"; then
    printf 'backend_gated'
  elif command -v "$(backend_bin "$name")" >/dev/null 2>&1; then
    printf 'backend_available'
  else
    printf 'backend_unavailable'
  fi
}

# backend_recommended NAME: does the model recommend this one here? kvm is the
# recommendation "when /dev/kvm exists"; the container backends are recommended
# for what they are, and the gated one is not recommended while it is gated.
backend_recommended() {
  local name="${1:-}"
  case "$name" in
    kvm)    [[ -e "${KVM_DEVICE}" ]] ;;
    podman) return 0 ;;
    docker) return 0 ;;
    *)      return 1 ;;
  esac
}

# backend_line NAME prints one row of the comparison list: a recommendation
# mark, the backend name, its availability on this host and its trade-off. Every
# word comes from the catalogue via tf, so the row is bilingual like the rest of
# the installer. Output is data, not a message: it is what the user compares, so
# it is printed even under --quiet.
backend_line() {
  local name="${1:-}" mark="backend_mark_blank"
  if backend_recommended "$name"; then mark="backend_mark_recommended"; fi
  printf '  %-2s %-8s %-30s %s\n' \
    "$(tf "$mark")" "$name" "$(tf "$(backend_status_key "$name")")" "$(tf "backend_trade_${name}")"
}

# backend_list prints the comparison the user has to weigh (docs/backend-model.md,
# the backend table). It goes to stdout and does not die, because both the
# interactive chooser and the non-interactive refusal show the same list.
backend_list() {
  heading_k backend_list_title
  printf '  %-2s %-8s %-30s %s\n' \
    '' "$(tf backend_list_backend)" "$(tf backend_list_available)" "$(tf backend_list_about)"
  printf '  %s\n' "$(printf '%.0s-' {1..72})"
  local name
  # A for loop, not `read` from a here-string: the installer is routinely run with
  # stdin on /dev/null, and a here-string would still take its fd from that.
  for name in $(backend_all_names); do
    backend_line "$name"
  done
}

# die_backend_gated NAME / die_backend_unimplemented NAME: the two refusals that
# need the implementation file in the message. One place builds them, because the
# catalogue wording names the file and the escape hatch and every caller must
# pass both (a missing argument used to print an empty parenthesis).
die_backend_gated() {
  die_k err_backend_disabled "${1}" "installer/lib/backend-${1}.sh" "${1}"
}

die_backend_unimplemented() {
  die_k err_backend_unimplemented "${1}" "installer/lib/backend-${1}.sh"
}

# backend_pick reads the choice from the terminal. Only reached with stdin on a
# TTY (the non-interactive path refuses instead), so this is a real question the
# user can answer. Invalid input is an error, never a silent default.
backend_pick() {
  local choice="" names_csv=""
  names_csv="$(backend_all_names | paste -sd, -)"
  if ! ui_read choice "$(tf backend_list_prompt "$names_csv")"; then
    die_k err_backend_choice_aborted
  fi
  if ! validate_backend "$choice"; then
    die_k err_backend_unknown "${choice}"
  fi
  if backend_gated "$choice"; then
    die_backend_gated "$choice"
  fi
  if backend_unimplemented "$choice"; then
    die_backend_unimplemented "$choice"
  fi
  if ! backend_ready "$choice"; then
    die_k err_backend_not_ready "${choice}" "$(backend_not_ready_hint "$choice")"
  fi
  printf '%s' "$choice"
}

backend_load() {
  local name="${1:-}" file
  if backend_gated "$name"; then
    die_backend_gated "$name"
  fi
  file="${BACKEND_DIR}/backend-${name}.sh"
  if [[ ! -r "$file" ]]; then
    die_k err_no_backend_impl "${name}" "${file}"
  fi
  # shellcheck source=/dev/null
  source "$file"
}

# backend_installed NAME: is NAME's CLI on PATH at all? Weaker than
# backend_ready (a binary can be installed and its daemon be down), which is
# what the list wants: "not installed" and "installed but not answering" are
# different answers to the user.
backend_installed() {
  command -v "$(backend_bin "${1:-}")" >/dev/null 2>&1
}

# resolve_backend NAME [explicit] turns the chosen backend into a loaded backend.
# It checks what the choice needs and nothing else, so a remembered name that a
# later release gated or stopped implementing is reported as such rather than
# loaded behind the user's back. The second argument says whether the name came
# from --backend (explicit) or from the remembered choice: the two need different
# words when the binary is missing, because only the remembered one has a
# "change the remembered choice" fix.
resolve_backend() {
  local name="${1:-}" explicit="${2:-0}"
  validate_backend "$name" || die_k err_backend_unknown "${name}"
  if backend_gated "$name"; then
    die_backend_gated "$name"
  fi
  if backend_unimplemented "$name"; then
    die_backend_unimplemented "$name"
  fi
  # The remembered choice can be a backend this host has not installed (anymore).
  # The point here is that the *remembered* one is gone and the command that
  # changes it is install.sh backend set NAME, so say that first. An explicit
  # --backend gets the plain "was requested but is not installed" from
  # resolve_engine instead: there is no remembered choice to correct.
  if [[ "$explicit" -eq 0 ]] && ! backend_installed "$name"; then
    die_k err_backend_pref_missing "${name}"
  fi
  resolve_engine "$name"
}

# resolve_engine NAME loads the requested backend and announces it. It never
# picks one: the remembered choice and the interactive chooser live in
# require_engine, which is where "no auto" lives, and an empty NAME here is a
# bug rather than a hint to guess.
resolve_engine() {
  local wanted="${1:-}" hint=""
  if [[ -z "$wanted" ]]; then
    die_k err_backend_not_chosen
  fi
  validate_backend "$wanted" || die_k err_backend_unknown "${wanted}"
  # The gate comes before the binary check: "--backend incus" must say incus is
  # not selectable in this version, whether or not incus happens to be installed.
  if backend_gated "$wanted"; then
    die_backend_gated "$wanted"
  fi
  if backend_unimplemented "$wanted"; then
    die_backend_unimplemented "$wanted"
  fi
  if ! command -v "$(backend_bin "$wanted")" >/dev/null 2>&1; then
    die_k err_backend_missing "${wanted}" "$(backend_bin "$wanted")"
  fi
  if ! backend_ready "$wanted"; then
    hint="$(backend_not_ready_hint "$wanted")"
    die_k err_backend_not_ready "${wanted}" "${hint}"
  fi
  ENGINE="$wanted"
  ENGINE_BIN="$(backend_bin "$wanted")"
  backend_load "$ENGINE"
  msg_k engine_line "${ENGINE}" "$(eng_version)"
}
# use_engine NAME switches to the backend recorded for an existing instance.
# An instance's backend is not a preference: it is where the instance lives.
use_engine() {
  local name="${1:-}"
  [[ -z "$name" ]] && return 0
  if ! command -v "$(backend_bin "$name")" >/dev/null 2>&1; then
    die_k err_engine_required "$(backend_bin "$name")"
  fi
  ENGINE="$name"
  ENGINE_BIN="$(backend_bin "$name")"
  backend_load "$ENGINE"
}
# run_engine is the raw, dry-run aware escape hatch. Backends that drive a
# container CLI use it; nothing outside a backend file should.
run_engine() {
  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    printf 'dry-run: %s' "$ENGINE_BIN"
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$ENGINE_BIN" "$@"
}

# --- shared helpers --------------------------------------------------------

# eng_host_port NAME PORT prints the host address a published container port is
# bound to, or nothing when the port is not published. Used by ./install.sh web
# and by doctor, so a container created before the web support existed still
# reports the address the backend actually assigned.
eng_host_port() {
  local name="$1" port="$2" out=""
  # a container with no published port makes the engine exit non-zero; keep the
  # lookup non-fatal under errexit and answer with an empty string instead
  out="$("$ENGINE_BIN" port "$name" "${port}/tcp" 2>/dev/null)" || true
  printf '%s\n' "${out%%$'\n'*}"
}

# engine_mount_suffix prints the SELinux relabel suffix a host bind mount needs.
# The container CLIs accept ":z"; a backend that labels its own mounts overrides
# this (Incus does), and a backend with no host bind mounts ignores it.
engine_mount_suffix() { printf ':z'; }

# detect_engines is the historical name for "which backends are present"; doctor
# and the tests still ask for it.
detect_engines() {
  backend_names
}
