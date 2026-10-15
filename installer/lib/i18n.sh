#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Message catalogue.
#
# The interface follows the locale the user already has, the way any other
# command-line tool does: LC_ALL wins, then LC_MESSAGES, then LANG. Anything
# unrecognised falls back to English, so an unusual or unset locale degrades to a
# working interface rather than an empty one.
#
# Strings are looked up by a stable key, never by their English text. That matters
# more than it looks: the TUI used to `case` on the rendered menu label, so
# translating the menu would have silently broken every branch. Keys keep the
# display text free to change.
#
# The catalogue is deliberately data, not code: `t` is the only function that
# knows how a translation is stored, so adding a language is adding a block.
# ---------------------------------------------------------------------------

# aw_locale: the effective locale, in the order the C library resolves it.
aw_locale() {
  printf '%s' "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
}

# aw_lang: the language part of that locale, lowercased (`zh_CN.UTF-8` -> `zh`).
aw_lang() {
  local raw
  raw="$(aw_locale)"
  raw="${raw%%:*}"      # strip an encoding suffix like `:en_US.UTF-8`
  raw="${raw%%.*}"      # strip `.UTF-8`
  raw="${raw%%@*}"      # strip a modifier like `@euro`
  raw="${raw%%_*}"      # strip the territory: `zh_CN` -> `zh`
  printf '%s' "${raw,,}"
}

# AW_LANG is the resolved language code. `C` and `POSIX` mean "no locale set",
# which is exactly the case that must land on English rather than on a language
# named "c".
AW_LANG="$(aw_lang)"
case "$AW_LANG" in
  ""|c|posix) AW_LANG=en ;;
esac

# An explicit override, for tests and for anyone whose locale is not what they
# want the installer to speak.
if [[ -n "${AW_LANG_OVERRIDE:-}" ]]; then
  AW_LANG="${AW_LANG_OVERRIDE,,}"
fi

# Collapse everything we do not have a catalogue for onto English. Doing this once,
# here, is what keeps the lookup below exhaustive: every `case` arm can assume the
# language is one it implements, so there is no reachable branch that produces an
# empty string for a key that exists. Without this a `de_DE` user would get the
# English text by accident (the catch-all arm) while `AW_LANG` still claimed `de`,
# which is the kind of half-truth that makes a later bug hard to read.
case "$AW_LANG" in
  en|zh) ;;
  *) AW_LANG=en ;;
esac

# --- the catalogue ---------------------------------------------------------

# t KEY [fallback]: the message for KEY in the current language.
#
# Every key must have an English entry: that is the one language the interface
# promises, and `tests/i18n.sh` asserts it, so a key added to only one language is
# caught here instead of showing up as a blank line in someone's terminal.
t() {
  local key="$1" fallback="${2:-}"
  local value=""

  case "$AW_LANG" in
    zh)
      case "$key" in
        # --- terminal interface ------------------------------------------
        tui_title)            value="agent-workspace — 编码智能体的容器" ;;
        tui_subtitle)         value="选择一项操作，或按 q 退出" ;;
        menu_create)          value="创建容器" ;;
        menu_list)            value="列出容器" ;;
        menu_enter)           value="进入容器（运行其中的智能体）" ;;
        menu_shell)           value="打开容器里的 shell" ;;
        menu_web)             value="打开智能体的 Web 界面" ;;
        menu_logs)            value="查看容器日志" ;;
        menu_restart)         value="启动 / 重启容器" ;;
        menu_stop)            value="停止容器" ;;
        menu_snapshot)        value="为容器创建快照" ;;
        menu_snapshots)       value="列出快照" ;;
        menu_rollback)        value="回滚容器" ;;
        menu_recover)         value="恢复容器" ;;
        menu_fork)            value="派生容器" ;;
        menu_upgrade)         value="升级容器到更新的镜像" ;;
        menu_doctor)          value="运行自检 doctor" ;;
        menu_remove)          value="删除容器" ;;
        menu_quit)            value="退出" ;;
        prompt_which)         value="哪一个容器？" ;;
        prompt_fork_which)    value="从哪个容器派生？" ;;
        prompt_remove_which)  value="删除哪个容器？" ;;
        prompt_label)         value="这次快照的标签" ;;
        prompt_snapshot_id)   value="快照 id（直接回车用最新的）" ;;
        prompt_new_name)      value="新容器的名字" ;;
        prompt_image)         value="镜像" ;;
        prompt_choice)        value="请选择" ;;
        no_containers)        value="还没有容器 — 先创建一个" ;;
        # --- what the installer says while it works -----------------------
        creating)             value="正在创建容器" ;;
        created)              value="容器已创建" ;;
        removing)             value="正在删除容器" ;;
        removed)              value="容器已删除" ;;
        starting)             value="正在启动" ;;
        stopped)              value="已停止" ;;
        snapshotted)          value="快照已创建" ;;
        rolled_back)          value="已回滚" ;;
        nothing_changed)      value="没有任何改动" ;;
        need_engine)          value="没有找到 podman 或 docker；请先安装其中一个" ;;
        gum_missing)          value="gum（charmbracelet）负责渲染交互界面，尚未安装。" ;;
        gum_install_prompt)   value="现在装到 %s 吗？[Y/n] " ;;
        gum_skipped)          value="改用普通提示继续" ;;
        # --- piped, no terminal -------------------------------------------
        pipe_no_tui)          value="install.sh：没有任何改动 —— 本次是非交互运行，无法启动交互式 TUI（stdin 是管道里的脚本）。" ;;
        pipe_run_with_tty)    value="请在有终端的地方运行，或者把子命令通过管道传进去：" ;;
        pipe_or_save)         value="也可以先存下来再用终端运行：" ;;
        *) value="" ;;
      esac
      ;;
    *)
      case "$key" in
        tui_title)            value="agent-workspace — containers for coding agents" ;;
        tui_subtitle)         value="pick an action, or press q to quit" ;;
        menu_create)          value="Create a container" ;;
        menu_list)            value="List containers" ;;
        menu_enter)           value="Enter a container (run its agent)" ;;
        menu_shell)           value="Open a shell in a container" ;;
        menu_web)             value="Open the agent's web UI" ;;
        menu_logs)            value="Show the log of a container" ;;
        menu_restart)         value="Start / restart a container" ;;
        menu_stop)            value="Stop a container" ;;
        menu_snapshot)        value="Snapshot a container" ;;
        menu_snapshots)       value="List snapshots" ;;
        menu_rollback)        value="Roll a container back" ;;
        menu_recover)         value="Recover a container" ;;
        menu_fork)            value="Fork a container" ;;
        menu_upgrade)         value="Upgrade a container to a newer image" ;;
        menu_doctor)          value="Run the doctor" ;;
        menu_remove)          value="Remove a container" ;;
        menu_quit)            value="Quit" ;;
        prompt_which)         value="Which container?" ;;
        prompt_fork_which)    value="Fork which container?" ;;
        prompt_remove_which)  value="Remove which container?" ;;
        prompt_label)         value="Label for this snapshot" ;;
        prompt_snapshot_id)   value="Snapshot id (enter to use the latest)" ;;
        prompt_new_name)      value="Name for the new container" ;;
        prompt_image)         value="Image" ;;
        prompt_choice)        value="choice" ;;
        no_containers)        value="no containers yet — create one first" ;;
        creating)             value="creating container" ;;
        created)              value="container created" ;;
        removing)             value="removing container" ;;
        removed)              value="container removed" ;;
        starting)             value="starting" ;;
        stopped)              value="stopped" ;;
        snapshotted)          value="snapshot created" ;;
        rolled_back)          value="rolled back" ;;
        nothing_changed)      value="nothing was changed" ;;
        need_engine)          value="neither podman nor docker is installed; install one of them first" ;;
        gum_missing)          value="gum (charmbracelet) renders the interactive interface and is not installed." ;;
        gum_install_prompt)   value="Install it into %s now? [Y/n] " ;;
        gum_skipped)          value="continuing with plain prompts" ;;
        pipe_no_tui)          value="install.sh: nothing was changed - this ran non-interactively, so the interactive TUI could not start (stdin is the piped script)." ;;
        pipe_run_with_tty)    value="Run it with a terminal, or pass a subcommand through the pipe:" ;;
        pipe_or_save)         value="Or save it first and run it with a terminal:" ;;
        *) value="" ;;
      esac
      ;;
  esac

  if [[ -n "$value" ]]; then
    printf '%s' "$value"
  else
    printf '%s' "$fallback"
  fi
}

# tf KEY [args...]: t, then printf, for messages that carry values. Kept separate
# so a translation containing `%` cannot turn into a format string by accident.
tf() {
  local key="$1"; shift
  local fmt
  fmt="$(t "$key" "")"
  # shellcheck disable=SC2059  # the format string is the translated message by design
  printf "$fmt" "$@"
}
