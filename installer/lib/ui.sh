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

# TTY_FD is set by install.sh when the script arrived on stdin: it holds a
# descriptor open on the controlling terminal, because fd 0 is the script itself
# and cannot be used for prompts. Empty when there is no terminal (CI, cron) or on
# a normal checkout run, where fd 0 already is the terminal.
UI_TTY_FD="${TTY_FD:-}"

# ui_interactive: can we ask the user anything at all?
ui_interactive() {
  if [[ -n "$UI_TTY_FD" ]]; then
    return 0
  fi
  [[ -t 0 ]]
}

# ui_read VAR [prompt]: read a line from the terminal, wherever it lives.
# Writes into the caller's variable rather than printing it, so the value is never
# re-parsed as shell text.
ui_read() {
  local __var="$1" __prompt="${2:-}" __line
  if [[ -n "$UI_TTY_FD" ]]; then
    [[ -n "$__prompt" ]] && printf '%s' "$__prompt" >&"$UI_TTY_FD"
    IFS= read -r -u "$UI_TTY_FD" __line || return 1
  else
    [[ -n "$__prompt" ]] && printf '%s' "$__prompt"
    IFS= read -r __line || return 1
  fi
  printf -v "$__var" '%s' "$__line"
}

ui_enabled() {
  [[ "${NO_TUI:-0}" -eq 0 ]] || return 1
  ui_interactive || return 1
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
    warn_k gum_missing
    return 1
  fi
  local answer
  msg_k gum_explain
  ui_read answer "$(tf gum_install_prompt "${HOME}")" || answer="n"
  case "${answer:-Y}" in
    n|N|no|NO) warn_k gum_skipped; return 1 ;;
  esac
  if install_gum; then
    return 0
  fi
  warn_k gum_install_failed
  return 1
}

install_gum() {
  local arch url tmp
  case "$(uname -m)" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) warn_k gum_no_build "$(uname -m)"; return 1 ;;
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
  ok_k gum_installed "${GUM_VERSION}" "${HOME}"
  return 0
}

# --- primitives ------------------------------------------------------------

# accordion_hint: the escape that turns off every attribute gum may have set.
# gum draws text with its own styling, and an escape sequence left open at the end
# of a line bleeds into whatever the shell prints next. Emitting a reset after each
# gum call keeps our own output stable regardless of what gum decided to do.
gum_reset() {
  [[ -n "$GUM_BIN" ]] || return 0
  printf '\033[0m'
}

# ui_header HEIGHT TITLE: a framed title block.
ui_header() {
  local title="${1}"
  if [[ -n "$GUM_BIN" ]]; then
    "$GUM_BIN" style --border rounded --border-foreground 212 --foreground 212 \
      --bold --padding "0 2" "$title"
    gum_reset
    return 0
  fi
  local width=${#title} rule=""
  local i
  for ((i = 0; i < width + 4; i++)); do rule+="─"; done
  printf '\n%s╭%s╮%s\n' "${DIM}" "$rule" "${RESET}"
  printf '%s│%s  %s%s%s  %s│%s\n' "${DIM}" "${RESET}" "${BOLD}" "$title" "${RESET}" "${DIM}" "${RESET}"
  printf '%s╰%s╯%s\n' "${DIM}" "$rule" "${RESET}"
}

# ui_subtitle: one dim line under a header.
ui_subtitle() {
  if [[ -n "$GUM_BIN" ]]; then
    "$GUM_BIN" style --foreground 240 "$1"
    gum_reset
  else
    printf '%s%s%s\n' "${DIM}" "$1" "${RESET}"
  fi
}

ui_rule() {
  if [[ -n "$GUM_BIN" ]]; then
    "$GUM_BIN" style --foreground 240 "$1"
    gum_reset
  else
    printf '%s\n' "$1"
  fi
}

# ui_choose HEADER ITEM...
#
# gum gives the arrow-key list. Without gum we print a numbered list and accept
# either the number or the literal item, so scripted use (`printf '2\n' |`) keeps
# working - that path is exercised by the installer's own tests.
ui_choose() {
  local header="${1}"
  shift
  if [[ -n "$GUM_BIN" ]]; then
    "$GUM_BIN" choose --header "$header" --cursor.foreground 212 \
      --selected.foreground 212 --cursor "▸ " "$@"
    return $?
  fi
  local index=1 item answer
  printf '\n%s%s%s\n' "${BOLD}" "$header" "${RESET}"
  for item in "$@"; do
    printf '  %s▸%s %s%d)%s %s\n' "${ACCENT}" "${RESET}" "${DIM}" "$index" "${RESET}" "$item"
    index=$((index + 1))
  done
  ui_read answer "$(printf '%s%s%s ' "${DIM}" "$(t prompt_choice)" "${RESET}")" || return 1
  answer="${answer#"${answer%%[![:space:]]*}"}"
  answer="${answer%"${answer##*[![:space:]]}"}"
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
  local prompt
  if [[ -n "$value" ]]; then
    prompt="${header} [${value}]: "
  else
    prompt="${header}: "
  fi
  ui_read answer "$prompt" || return 1
  printf '%s' "${answer:-$value}"
}

ui_secret() {
  local header="${1}" answer
  if [[ -n "$GUM_BIN" ]]; then
    "$GUM_BIN" input --password --header "$header"
    return $?
  fi
  # `read -s` cannot address an arbitrary descriptor, so a piped run echoes the
  # secret unless `stty` is told to silence the terminal the descriptor points at.
  # Both branches turn echoing off around the read and restore it afterwards, even
  # when the read fails, so an interrupted prompt cannot leave the terminal deaf.
  local answer
  if [[ -n "$UI_TTY_FD" ]]; then
    printf '%s: ' "$header" >&"$UI_TTY_FD"
    stty -echo <&"$UI_TTY_FD" 2>/dev/null || true
    if ! IFS= read -r -u "$UI_TTY_FD" answer; then
      stty echo <&"$UI_TTY_FD" 2>/dev/null || true
      printf '\n' >&"$UI_TTY_FD"
      return 1
    fi
    stty echo <&"$UI_TTY_FD" 2>/dev/null || true
    printf '\n' >&"$UI_TTY_FD"
  else
    printf '%s: ' "$header"
    if ! IFS= read -rs answer; then
      printf '\n'
      return 1
    fi
    printf '\n'
  fi
  printf '%s' "$answer"
}

ui_confirm() {
  local question="${1}" default="${2:-yes}" answer
  if [[ -n "$GUM_BIN" ]]; then
    "$GUM_BIN" confirm --default="${default}" "$question"
    return $?
  fi
  local prompt
  if [[ "$default" == "no" ]]; then
    prompt="${question} [y/N] "
  else
    prompt="${question} [Y/n] "
  fi
  ui_read answer "$prompt" || return 1
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
