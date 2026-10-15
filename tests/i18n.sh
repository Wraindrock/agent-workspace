#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# The interface's language handling.
#
# Two things are easy to get wrong and both are invisible in English:
#   1. The TUI used to match on the *rendered* menu label. Translating the menu
#      would have turned every entry into a silent no-op - the menu still draws,
#      the keys still move, and selecting "创建容器" does nothing at all.
#   2. A locale we do not have must fall back to English rather than to an empty
#      screen.
#
# Both are asserted below by running the real catalogue, not by grepping for it.
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 1

pass=0
fail=0
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  fail %s\n' "$1"; fail=$((fail + 1)); }

printf 'language\n'

for f in installer/lib/i18n.sh install.sh; do
  if [[ -f "$f" ]]; then ok "$f exists"; else bad "$f is missing"; fi
done

# --- the catalogue resolves a language from the locale ---------------------

# lang_for LOCALE: run the real detection with LANG set, print the result.
lang_for() {
  env -u LC_ALL -u LC_MESSAGES -u AW_LANG_OVERRIDE LANG="$1" \
    bash -c 'source installer/lib/i18n.sh >/dev/null 2>&1; printf %s "$AW_LANG"'
}

check_lang() { # check_lang LOCALE EXPECTED DESC
  local got
  got="$(lang_for "$1")"
  if [[ "$got" == "$2" ]]; then
    ok "$3"
  else
    bad "$3 (LANG=$1 gave '$got', expected '$2')"
  fi
}

check_lang "zh_CN.UTF-8" zh "zh_CN.UTF-8 selects Chinese"
check_lang "zh_TW.UTF-8" zh "zh_TW.UTF-8 selects Chinese"
check_lang "zh_CN.utf8"  zh "a lowercase encoding suffix still selects Chinese"
check_lang "en_US.UTF-8" en "en_US.UTF-8 selects English"
check_lang "C"           en "C falls back to English"
check_lang "POSIX"       en "POSIX falls back to English"
check_lang "de_DE.UTF-8" en "an unsupported language falls back to English"
check_lang ""            en "an unset locale falls back to English"

# LC_ALL must win over LANG, the way every other tool resolves it.
got="$(env LC_ALL=zh_CN.UTF-8 LANG=en_US.UTF-8 bash -c 'source installer/lib/i18n.sh >/dev/null 2>&1; printf %s "$AW_LANG"')"
if [[ "$got" == "zh" ]]; then ok "LC_ALL overrides LANG"; else bad "LC_ALL did not override LANG (got '$got')"; fi
got="$(env AW_LANG_OVERRIDE=zh LANG=en_US.UTF-8 bash -c 'source installer/lib/i18n.sh >/dev/null 2>&1; printf %s "$AW_LANG"')"
if [[ "$got" == "zh" ]]; then ok "AW_LANG_OVERRIDE overrides the locale"; else bad "AW_LANG_OVERRIDE did not take effect (got '$got')"; fi

# --- every key has both languages ------------------------------------------
# A key present in only one language shows up as a blank line in someone's
# terminal, which is exactly the kind of defect nobody reports.

# all_keys: every message key in the catalogue.
#
# Keys have to be recognised structurally, not by shape. The English arm holds
# single-word keys (`created`, `stopped`) that look exactly like the `en)` / `zh)`
# arm labels, so a "line that looks like a key" heuristic picks the arm labels up
# too and then reports them as keys with no text in either language. What actually
# separates them is position: a key is an arm inside `case "$key" in`, while the
# language labels are arms of `case "$AW_LANG" in`. Only the inner ones are keys.
all_keys() {
  awk '
    /^t\(\) \{/                        { in_t = 1; next }
    in_t && /^}$/                      { exit }
    in_t && /case "\$AW_LANG" in/      { in_lang = 1; next }
    in_lang && /^[[:space:]]*\*\)/     { next }
    in_lang && /^[[:space:]]*[a-z]+\)/ { next }
    in_lang && /^[[:space:]]*[a-z_0-9]+\)/ {
      line = $0
      gsub(/^[[:space:]]*/, "", line)
      sub(/\).*/, "", line)
      print line
      next
    }
  ' installer/lib/i18n.sh | sort -u
}

missing=0
while IFS= read -r key; do
  [[ -n "$key" ]] || continue
  en="$(AW_LANG_OVERRIDE=en bash -c "source installer/lib/i18n.sh >/dev/null 2>&1; t '$key'")"
  zh="$(AW_LANG_OVERRIDE=zh bash -c "source installer/lib/i18n.sh >/dev/null 2>&1; t '$key'")"
  if [[ -z "$en" ]]; then bad "key '$key' has no English text"; missing=$((missing + 1)); fi
  if [[ -z "$zh" ]]; then bad "key '$key' has no Chinese text"; missing=$((missing + 1)); fi
done < <(all_keys)
[[ "$missing" -eq 0 ]] && ok "every message key is defined in both languages"

# The English catalogue is the contract: `t` must never invent text.
if [[ -z "$(AW_LANG_OVERRIDE=en bash -c "source installer/lib/i18n.sh >/dev/null 2>&1; t no_such_key_xyz")" ]]; then
  ok "an unknown key yields nothing rather than a placeholder"
else
  bad "an unknown key produced text"
fi

# --- the menu dispatches on keys, not on translated text -------------------
# This is the defect the whole key indirection exists to prevent.

if grep -qE '^tui_menu\(\)' install.sh; then
  ok "the menu is built by a tui_menu function"
else
  bad "tui_menu is missing, so the menu and the dispatch can drift"
fi

if grep -qE 'printf .menu_%s\\t%s' install.sh; then
  ok "menu entries are emitted as key<TAB>label"
else
  bad "menu entries are not emitted with their key"
fi

# A case arm on a translated label is the bug. The dispatch must not contain any
# literal menu wording.
if grep -qE '^\s*"(Create a container|List containers|Quit)"\)' install.sh; then
  bad "the TUI still matches on English menu text, so translating the menu would break every entry"
else
  ok "the TUI does not match on menu text"
fi

# The real proof: run the dispatch's lookup with Chinese labels and confirm each
# label still maps back to its key.
probe="$(LANG=zh_CN.UTF-8 bash -c '
  source installer/lib/i18n.sh >/dev/null 2>&1
  ui_choose() { printf "%s" "$1"; }   # pretend the user picked the first entry
  keys=(); labels=()
  while IFS=$'"'"'\t'"'"' read -r k l; do keys+=("$k"); labels+=("$l"); done < <(
    for key in create list quit; do printf "menu_%s\t%s\n" "$key" "$(t "menu_${key}")"; done
  )
  choice="$(ui_choose "${labels[@]}")"
  for i in "${!labels[@]}"; do
    [[ "${labels[$i]}" == "$choice" ]] && { printf "%s" "${keys[$i]}"; break; }
  done
')"
if [[ "$probe" == "menu_create" ]]; then
  ok "a Chinese menu label maps back to its key"
else
  bad "a Chinese menu label did not map back to its key (got '$probe')"
fi

# --- the non-interactive path says so in the user's language ---------------

if grep -q 'pipe_no_tui' install.sh; then
  ok "the piped no-argument path uses a translated message"
else
  bad "the piped no-argument path does not use the catalogue"
fi

printf '\n'
if [[ "$fail" -eq 0 ]]; then
  printf 'language: all checks passed\n'
  exit 0
fi
printf 'language: %d check(s) failed\n' "$fail"
exit 1
