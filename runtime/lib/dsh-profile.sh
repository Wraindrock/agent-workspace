#!/usr/bin/env bash
# The image's dsh plugin set, seeded into an agent's home.
#
# Sourced by runtime/lib/firstboot.sh. The functions here are also exercised
# directly by tests/firstboot.sh.
#
# The image ships a dsh *profile* -- this project's default plugin set -- under
# $DSH_PROFILE_SRC. dsh reads profiles from the agent's own $DSH_HOME/profiles,
# which lives in the agent's volume, so the image's copy has to be seeded there
# once. Three properties are load-bearing:
#
#   * the seed is idempotent: a second run must not touch a profile that is
#     already current, because firstboot runs again for every new container
#     (create, upgrade, recover, rollback, fork) over the same volume;
#   * the plugin set is ours and the patch layer is the user's: an upgrade
#     refreshes the dependency list, the lockfile and node_modules as a unit and
#     never writes cordis.patch.yml or anything else the user put in there;
#   * a profile this image did not create is only adopted when its own files are
#     byte-identical to the shipped ones. A profile the user changed keeps their
#     version and says so, instead of being silently replaced.
#
# The digest recorded in the shipped profiles.version decides which case
# applies: it changes exactly when this project changes the set, so a container
# created from a newer image refreshes the set and one created from the same
# image does nothing at all.

DSH_PROFILE_SRC="${DSH_PROFILE_SRC:-/usr/share/agent-workspace/dsh/profiles}"
DSH_PROFILE_VERSION_FILE="${DSH_PROFILE_VERSION_FILE:-/usr/share/agent-workspace/dsh/profiles.version}"

# The record of what was seeded, kept inside the profile directory.
DSH_PROFILE_MANIFEST=".agent-workspace-profile"

# The files in a profile that belong to the image. Everything else -- above all
# cordis.patch.yml -- belongs to the user.
DSH_PROFILE_OWNED_FILES=(package.json pnpm-workspace.yaml pnpm-lock.yaml)
DSH_PROFILE_OWNED_DIRS=(node_modules)

dsh_profiles_version() {
  [[ -r "$DSH_PROFILE_VERSION_FILE" ]] || return 1
  head -n1 "$DSH_PROFILE_VERSION_FILE"
}

_dsh_file_digest() {
  sha256sum "$1" 2>/dev/null | awk '{ print $1 }'
}

# _dsh_profile_manifest_write SRC DEST VERSION
#   Records the version in place and the digest of each file installed from SRC,
#   by read-modify-atomic-replace so an interrupted firstboot cannot leave a
#   half-written record behind.
_dsh_profile_manifest_write() {
  local src="$1" dest="$2" version="$3" file tmp
  tmp="${dest}/${DSH_PROFILE_MANIFEST}.tmp"
  {
    printf 'version %s\n' "$version"
    for file in "${DSH_PROFILE_OWNED_FILES[@]}"; do
      [[ -f "${src}/${file}" ]] || continue
      printf 'owned %s %s\n' "$file" "$(_dsh_file_digest "${src}/${file}")"
    done
  } >"$tmp" || return 1
  mv -f "$tmp" "${dest}/${DSH_PROFILE_MANIFEST}"
}

_dsh_profile_manifest_version() {
  local dest="$1"
  [[ -r "${dest}/${DSH_PROFILE_MANIFEST}" ]] || return 1
  awk '$1 == "version" { print $2; found = 1 } END { exit found ? 0 : 1 }' \
    "${dest}/${DSH_PROFILE_MANIFEST}"
}

# _dsh_profile_owned_intact DEST -- every file this image installed is still
# byte-identical to what its manifest recorded.
_dsh_profile_owned_intact() {
  local dest="$1" kind file recorded actual
  [[ -r "${dest}/${DSH_PROFILE_MANIFEST}" ]] || return 1
  while read -r kind file recorded; do
    [[ "$kind" == "owned" ]] || continue
    [[ -f "${dest}/${file}" ]] || return 1
    actual="$(_dsh_file_digest "${dest}/${file}")"
    [[ -n "$actual" && "$actual" == "$recorded" ]] || return 1
  done <"${dest}/${DSH_PROFILE_MANIFEST}"
  return 0
}

# _dsh_profile_carries_set SRC DEST -- DEST's own files are exactly the shipped
# ones, which is what makes adopting a profile this image did not create safe.
_dsh_profile_carries_set() {
  local src="$1" dest="$2" file
  for file in "${DSH_PROFILE_OWNED_FILES[@]}"; do
    [[ -f "${src}/${file}" ]] || continue
    [[ -f "${dest}/${file}" ]] || return 1
    [[ "$(_dsh_file_digest "${src}/${file}")" == "$(_dsh_file_digest "${dest}/${file}")" ]] || return 1
  done
  local dir
  for dir in "${DSH_PROFILE_OWNED_DIRS[@]}"; do
    [[ -d "${src}/${dir}" ]] || continue
    [[ -d "${dest}/${dir}" ]] || return 1
  done
  return 0
}

# _dsh_profile_copy SRC DEST -- install the set, and only the set.
_dsh_profile_copy() {
  local src="$1" dest="$2" file dir
  install -d -m 0755 "$dest" || return 1
  for file in "${DSH_PROFILE_OWNED_FILES[@]}"; do
    [[ -f "${src}/${file}" ]] || continue
    cp -a "${src}/${file}" "${dest}/${file}" || return 1
  done
  for dir in "${DSH_PROFILE_OWNED_DIRS[@]}"; do
    [[ -d "${src}/${dir}" ]] || continue
    rm -rf "${dest:?}/${dir}" || return 1
    cp -a "${src}/${dir}" "${dest}/${dir}" || return 1
  done
  # dsh's template for this profile: seeded once, never overwritten afterwards.
  if [[ -f "${src}/cordis.patch.yml" && ! -e "${dest}/cordis.patch.yml" ]]; then
    cp -a "${src}/cordis.patch.yml" "${dest}/cordis.patch.yml" || return 1
  fi
}

# _dsh_profile_owner DIR OWNER [recursive]
#   Best effort. A user namespace that cannot name the agent's uid at all (the
#   rootless single-id map) makes every chown fail with EINVAL while the files
#   are already the agent's from inside the container, so that case is reported
#   as the limitation it is rather than as a provisioning failure.
_dsh_profile_owner() {
  local dir="$1" owner="$2" recursive="${3:-1}" uid
  [[ -n "$owner" ]] || return 0
  uid="$(id -u "$owner" 2>/dev/null || true)"
  if [[ -n "$uid" ]] && declare -F id_is_mapped >/dev/null 2>&1 && ! id_is_mapped "$uid"; then
    [[ "$(stat -c '%u' "$dir")" == "$uid" ]] && return 0
    log "left ${dir} owned by $(stat -c '%u:%g' "$dir"): uid ${uid} is not mapped in this user namespace"
    return 0
  fi
  if [[ "$recursive" == "1" ]]; then
    chown -R "${owner}:${owner}" "$dir" 2>/dev/null && return 0
  else
    chown "${owner}:${owner}" "$dir" 2>/dev/null && return 0
  fi
  warn "could not set the owner of ${dir} to ${owner}"
  return 1
}

# seed_dsh_profiles HOME [OWNER]
#   Seeds or refreshes the image's dsh profiles into HOME/.dsh/profiles.
#   Returns 0 when every shipped profile is in the state the image intends --
#   seeded, refreshed, already current, or deliberately left alone -- and 1 when
#   one could not be written. It never exits the caller: firstboot still has to
#   write its completion marker.
seed_dsh_profiles() {
  local home="${1:-}" owner="${2:-}" version src name dest manifest_version dest_existed intact
  local seeded=0 refreshed=0 adopted=0 current=0 kept=0 failed=0

  if [[ -z "$home" || ! -d "$home" ]]; then
    warn "no home directory to seed the dsh profiles into"
    return 1
  fi
  if [[ ! -d "$DSH_PROFILE_SRC" ]]; then
    log "this image ships no dsh profiles"
    return 0
  fi
  if ! version="$(dsh_profiles_version)" || [[ -z "$version" ]]; then
    warn "the image ships dsh profiles without a version stamp (${DSH_PROFILE_VERSION_FILE}); not seeding"
    return 1
  fi

  install -d -m 0755 "${home}/.dsh/profiles" || { warn "could not create ${home}/.dsh/profiles"; return 1; }
  _dsh_profile_owner "${home}/.dsh" "$owner" 0 || failed=$((failed + 1))
  _dsh_profile_owner "${home}/.dsh/profiles" "$owner" 0 || failed=$((failed + 1))

  shopt -s nullglob
  local -a shipped=("${DSH_PROFILE_SRC}"/*/)
  shopt -u nullglob
  if (( ${#shipped[@]} == 0 )); then
    warn "no profiles to seed under ${DSH_PROFILE_SRC}"
    return 1
  fi

  for src in "${shipped[@]}"; do
    name="$(basename "${src%/}")"
    dest="${home}/.dsh/profiles/${name}"
    manifest_version="$(_dsh_profile_manifest_version "$dest" || true)"
    # Whether the files this image owns are still the ones it installed. Checking
    # this even at the same version is what turns "the user edited the profile"
    # into a warning instead of a silent "current".
    intact=0
    _dsh_profile_owned_intact "$dest" && intact=1

    if [[ "$manifest_version" == "$version" && "$intact" == 1 ]]; then
      current=$((current + 1))
    elif [[ -n "$manifest_version" && "$intact" == 0 ]]; then
      kept=$((kept + 1))
      warn "kept the changed dsh profile ${name}: it differs from plugin set ${version} (remove ${dest} to take the image's set)"
    elif [[ -z "$manifest_version" && -d "$dest" ]] && ! _dsh_profile_carries_set "$src" "$dest"; then
      kept=$((kept + 1))
      warn "kept the existing dsh profile ${name}: this image did not create it (remove ${dest} to take the image's set)"
    else
      dest_existed=0
      [[ -d "$dest" ]] && dest_existed=1
      if _dsh_profile_copy "$src" "$dest" &&
        _dsh_profile_manifest_write "$src" "$dest" "$version" &&
        _dsh_profile_owner "$dest" "$owner"; then
        if [[ -n "$manifest_version" ]]; then
          refreshed=$((refreshed + 1))
          log "refreshed the dsh profile ${name} to plugin set ${version}"
        elif (( dest_existed == 1 )); then
          adopted=$((adopted + 1))
          log "adopted the dsh profile ${name} (plugin set ${version})"
        else
          seeded=$((seeded + 1))
          log "seeded the dsh profile ${name} (plugin set ${version})"
        fi
      else
        failed=$((failed + 1))
        warn "could not install the dsh profile ${name} (plugin set ${version})"
      fi
    fi
  done

  log "dsh profiles: ${seeded} seeded, ${refreshed} refreshed, ${adopted} adopted, ${current} current, ${kept} kept, ${failed} failed"
  (( failed == 0 ))
}
