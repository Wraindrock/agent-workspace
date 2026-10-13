#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Terminal user interface.
#
# The nice interactive experience uses gum (https://github.com/charmbracelet/gum),
# which the installer offers to fetch into ~/.local/bin on first run. Every
# primitive degrades to plain prompts so the script still works over ssh on a
# machine without gum, and tests can drive it with --no-tui.
# ---------------------------------------------------------------------------

GUM_VERSION="${GUM_VERSION:-0.16.2}"
GUM_BIN="${GUM_BIN:-}"

ui_enabled() {
  [[ "${NO_TUI:-0}" -eq 0 ]] || return 1
  [[ -t 0 ]] || return 1
  [[ -t 1 ]] || return 1
  return 0
}

resolve_gum() {
  if [[ -n "$GUM_BIN" ]] && command -v "$GUM_BIN" >/dev/null 2>&1; then
    return 0
  fi
  if command -v gum >/dev/null 2>&1; then
    GUM_BIN="gum"
    return 0
  fi
  GUM_BIN=""
  return 1
}

# ensure_gum returns 0 when the TUI is available.
ensure_gum() {
  resolve_gum && return 0
  if ! ui_enabled; then
    warn "gum is not installed; continuing with plain prompts"
    return 1
  fi
  local answer
  printf 'gum (charmbracelet) renders the interactive interface and is not installed.\n'
  printf 'Install it into %s now? [Y/n] ' "${HOME}/.local/bin"
  read -r answer || answer="n"
  case "${answer:-Y}" in
    n|N|no|NO) warn "continuing with plain prompts"; return 1 ;;
  esac
  if install_gum; then
    return 0
  fi
  warn "could not install gum; continuing with plain prompts"
  return 1
}

install_gum() {
  local arch url tmp
  case "$(uname -m)" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) warn "no gum build for $(uname -m)"; return 1 ;;
  esac
  tmp="$(mktemp -d)"
  local candidate
  for candidate in "${arch}" "$([[ "$arch" == x86_64 ]] && printf 'amd64' || printf 'aarch64')"; do
    url="https://github.com/charmbracelet/gum/releases/download/v${GUM_VERSION}/gum_${GUM_VERSION}_Linux_${candidate}.tar.gz"
    if curl -fsSL "$url" -o "${tmp}/gum.tar.gz" 2>/dev/null; then
      break
    fi
  done
  if [[ ! -s "${tmp}/gum.tar.gz" ]]; then
    rm -rf "$tmp"
    return 1
  fi
  if ! tar -xzf "${tmp}/gum.tar.gz" -C "$tmp" gum 2>/dev/null; then
    rm -rf "$tmp"
    return 1
  fi
  install -d -m 0755 "${HOME}/.local/bin"
  install -m 0755 "${tmp}/gum" "${HOME}/.local/bin/gum"
  rm -rf "$tmp"
  GUM_BIN="${HOME}/.local/bin/gum"
  ok "installed gum ${GUM_VERSION} to ${HOME}/.local/bin/gum"
  return 0
}

# --- primitives ------------------------------------------------------------

ui_header() {
  if [[ -n "$GUM_BIN" ]]; then
    "$GUM_BIN" style --bold --foreground 212 "${1}"
  else
    printf '\n%s== %s ==%s\n' "${BOLD}" "${1}" "${RESET}"
  fi
}

ui_rule() {
  if [[ -n "$GUM_BIN" ]]; then
    "$GUM_BIN" style --foreground 240 "${1}"
  else
    printf '%s\n' "${1}"
  fi
}

ui_choose() {
  local header="${1}"
  shift
  if [[ -n "$GUM_BIN" ]]; then
    "$GUM_BIN" choose --header "$header" --cursor.foreground 212 "$@"
    return $?
  fi
  local index=1 item answer
  printf '%s\n' "$header"
  for item in "$@"; do
    printf '  %s) %s\n' "$index" "$item"
    index=$((index + 1))
  done
  printf 'choice: '
  read -r answer || return 1
  if [[ "$answer" =~ ^[0-9]+$ ]] && [[ "$answer" -ge 1 ]] && [[ "$answer" -le "$#" ]]; then
    local picked=1
    for item in "$@"; do
      if [[ "$picked" -eq "$answer" ]]; then
        printf '%s\n' "$item"
        return 0
      fi
      picked=$((picked + 1))
    done
  fi
  [[ -n "$answer" ]] || return 1
  printf '%s\n' "$answer"
}

ui_input() {
  local header="${1}" value="${2:-}" placeholder="${3:-}" answer
  if [[ -n "$GUM_BIN" ]]; then
    "$GUM_BIN" input --header "$header" --placeholder "$placeholder" --value "$value"
    return $?
  fi
  if [[ -n "$value" ]]; then
    printf '%s [%s]: ' "$header" "$value"
  else
    printf '%s: ' "$header"
  fi
  read -r answer || return 1
  printf '%s' "${answer:-$value}"
}

ui_secret() {
  local header="${1}" answer
  if [[ -n "$GUM_BIN" ]]; then
    "$GUM_BIN" input --password --header "$header"
    return $?
  fi
  printf '%s: ' "$header"
  read -rs answer || return 1
  printf '\n'
  printf '%s' "$answer"
}

ui_confirm() {
  local question="${1}" default="${2:-yes}" answer
  if [[ -n "$GUM_BIN" ]]; then
    "$GUM_BIN" confirm --default="${default}" "$question"
    return $?
  fi
  if [[ "$default" == "no" ]]; then
    printf '%s [y/N] ' "$question"
  else
    printf '%s [Y/n] ' "$question"
  fi
  read -r answer || return 1
  answer="${answer:-${default:0:1}}"
  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

ui_spin() {
  local title="${1}"
  shift
  if [[ -n "$GUM_BIN" ]]; then
    "$GUM_BIN" spin --spinner dot --title "$title" -- "$@"
    return $?
  fi
  printf '%s\n' "$title"
  "$@"
}
