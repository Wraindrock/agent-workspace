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
# Keys have to be recognised structurally, not by shape, because a key and an arm
# label can look identical: the English catalogue holds single-word keys (`pulling`,
# `started`, `restarted`) and the language switch has single-word arms (`en)`,
# `zh)`). Telling them apart by their text is impossible and by their "shape"
# heuristic is how this went wrong the first time - an earlier version skipped
# every `^[a-z]+)$` line to drop the arm labels, which silently swallowed those
# three keys, so the completeness check never looked at them. A key that the
# checker cannot see is a key that can go missing.
#
# Position is the only sound discriminator: an arm label appears directly under
# `case "$AW_LANG" in` and is followed by another `case`, while a key appears under
# that inner `case "$key" in`. So track the depth - enter the language switch, then
# enter the key switch, and only collect arms seen at the inner depth.
all_keys() {
  awk '
    /^t\(\) \{/                         { in_t = 1; next }
    in_t && /^}$/                       { exit }
    in_t && /case "\$AW_LANG" in/       { in_lang = 1; next }
    in_lang && /case "\$key" in/        { in_key = 1; next }
    in_key && /^[[:space:]]*\*\)/       { next }   # the catch-all arm
    in_key && /^[[:space:]]*[a-zA-Z_0-9]+\)/ {
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

# A key defined twice in the same language is worse than a missing one: `case`
# silently takes the first arm and shadows the rest, so the catalogue reads as if
# the later - usually newer - text is live when it is dead. shellcheck flags this
# as SC2221/SC2222, but only where shellcheck runs; this check is engine-free and
# always on, so a key added twice fails the suite even on a bare checkout.
#
# Each key must appear exactly twice in the file: once per language. Anything
# else is either a duplicate (>2) or single-language (<2).
dupes="$(awk '
  /value="/ {
    line = $0
    gsub(/^[[:space:]]*/, "", line)
    sub(/\).*/, "", line)
    if (line ~ /^[a-zA-Z_][a-zA-Z_0-9]*$/) print line
  }
' installer/lib/i18n.sh | sort | uniq -c | awk '$1 != 2 { printf "%s(x%s) ", $2, $1 }')"
if [[ -z "$dupes" ]]; then
  ok "no message key is defined twice in one language"
else
  bad "each key must be defined exactly once per language, but found: ${dupes}"
fi

# The English catalogue is the contract: `t` must never invent text.
if [[ -z "$(AW_LANG_OVERRIDE=en bash -c "source installer/lib/i18n.sh >/dev/null 2>&1; t no_such_key_xyz")" ]]; then
  ok "an unknown key yields nothing rather than a placeholder"
else
  bad "an unknown key produced text"
fi

# A message that *starts* with a flag name is a message that `printf` reads as an
# option: it prints `printf: --: invalid option` and renders nothing, so the user gets
# a bare "x" from a `die`. The catalogue must survive its own text.
leading="$(AW_LANG_OVERRIDE=en bash -c 'source installer/lib/i18n.sh >/dev/null 2>&1; tf err_backend_missing podman podman' 2>/dev/null)"
if [[ "$leading" == "--backend/--engine podman was requested but podman is not installed" ]]; then
  ok "a message that begins with a flag still renders"
else
  bad "a message beginning with '-' rendered as '${leading}' (printf needs --)"
fi

# Every user-facing message must go through the catalogue. A helper called with an
# English literal is a message that cannot be translated, and the earlier sweep for
# these missed install.sh entirely because it only looked at installer/lib/*.sh --
# which is exactly why this is an assertion and not a habit. The machine-readable
# output (the `CONTAINER=`/`NAME` declaration format) is not a message and does not
# use these helpers, so it is out of scope here.
unkeyed="$(grep -rnE '\b(die|warn|msg|ok|heading|report_ok|report_bad|ui_input)[[:space:]]+"[A-Za-z]' \
  install.sh installer/lib/*.sh 2>/dev/null | grep -v '^installer/lib/i18n.sh:' || true)"
if [[ -z "$unkeyed" ]]; then
  ok "every user-facing message goes through the catalogue"
else
  bad "these messages bypass the catalogue and cannot be translated:
${unkeyed}"
fi

# ... and a key that does not exist is just as silent: `t` yields an empty string
# for an unknown key, so `die_k err_typo` exits non-zero having printed nothing.
# That is how a backend error shipped with no message at all. Assert that every
# key the catalogue helpers are called with actually resolves.
keys_used="$(grep -rnE '\b(die_k|warn_k|msg_k|ok_k|bad_k|report_ok_k|report_bad_k|heading_k)[[:space:]]+[A-Za-z_][A-Za-z_0-9]*' \
  install.sh installer/lib/*.sh 2>/dev/null \
  | grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' \
  | grep -oE '\b(die_k|warn_k|msg_k|ok_k|bad_k|report_ok_k|report_bad_k|heading_k)[[:space:]]+[A-Za-z_][A-Za-z_0-9]*' \
  | awk '{print $2}' | sort -u || true)"
missing_keys="$(KEYLIST="${keys_used}" AW_LANG_OVERRIDE=en bash -c '
  source installer/lib/i18n.sh >/dev/null 2>&1 || exit 1
  for k in $KEYLIST; do
    [[ -n "$(t "$k")" ]] || printf "%s " "$k"
  done
' 2>/dev/null || true)"
if [[ -z "$missing_keys" ]]; then
  ok "every message key the code calls resolves in the catalogue"
else
  bad "these message keys are called but not defined (they would print nothing):
${missing_keys}"
fi

# The helper sweep above only sees calls that go *through* a message helper. A bare
# `printf` of an English sentence is the same defect and hides from it - that is how the
# gum explanation survived the first pass. The rule is "three lower-case words in a row",
# which is what prose looks like and what machine output does not: a format string has a
# `%`, a command fragment has flags, and a field list is not a sentence. The three
# exclusions are not a loophole, they are the published boundary - README.md's "Interface
# language" names all three, and the first two print before the catalogue has even been
# fetched, so they could not be translated if they wanted to be.
prose="$(grep -rnE "printf +'[^']*[a-z]+ [a-z]+ [a-z]+" install.sh installer/lib/*.sh 2>/dev/null \
  | grep -v '^installer/lib/i18n.sh:' \
  | grep -vE 'needs bash 4\.4|fetched %d files|# name agent mode' || true)"
if [[ -z "$prose" ]]; then
  ok "no English prose is printed outside the catalogue"
else
  bad "these English sentences are printed with a bare printf:
${prose}"
fi

# --- the --help block, whose left column is not translated -----------------
# `usage_text` is the one message stored as a block rather than as keys, because
# its left column is the command and flag surface itself. That column is what
# people copy and what tests/contract.sh asserts entry by entry, so it must be
# byte-identical in every language: only the descriptions to its right may differ.
# If a translator ever renames a flag inside the block, this is what catches it.

surface_of() { # surface_of LANG
  # The surface is every subcommand and every flag the block mentions, including
  # the ones only named inside a description (`add --purge-snapshots`). Comparing
  # the sorted sets is what catches a flag renamed in one language; comparing the
  # raw text would only catch it where the padding happens to line up.
  AW_LANG_OVERRIDE="$1" bash -c "source installer/lib/i18n.sh >/dev/null 2>&1; usage_text" \
    | grep -oE '(\./install\.sh [a-z|]+|--[a-z][a-z-]*)' \
    | sort -u
}

usage_surface_diff="$(diff <(surface_of en) <(surface_of zh) || true)"
if [[ -z "$usage_surface_diff" ]]; then
  ok "the --help command and flag surface is identical in both languages"
else
  bad "the --help command/flag surface drifted between languages:
${usage_surface_diff}"
fi

# Guard the check itself: the surface must be non-trivial, or a block that failed
# to render would compare equal to another empty one and pass.
if [[ "$(surface_of en | wc -l)" -ge 20 ]]; then
  ok "the --help surface extracted from the block is non-trivial"
else
  bad "only $(surface_of en | wc -l) command/flag tokens found in --help; the check would be vacuous"
fi

# And the block must actually be translated, not a copy of the English one.
usage_zh="$(AW_LANG_OVERRIDE=zh bash -c "source installer/lib/i18n.sh >/dev/null 2>&1; usage_text")"
if [[ "$usage_zh" == *"打开交互式 TUI"* ]]; then
  ok "the --help block is translated into Chinese"
else
  bad "the Chinese --help block is missing or still English"
fi

# The documented subcommands must survive translation: these are the tokens
# tests/contract.sh pulls out of the English block.
for token in "./install.sh create" "./install.sh rollback NAME [--to ID]" \
  "--dry-run, -n" "--help-agents" "--purge-snapshots"; do
  if [[ "$usage_zh" == *"$token"* ]]; then
    ok "the Chinese --help block still documents '${token}'"
  else
    bad "the Chinese --help block lost '${token}'"
  fi
done

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
