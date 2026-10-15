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
        # --- section headings and table headers ---------------------------
        head_new_containers)  value="新建智能体容器" ;;
        head_creating)        value="正在创建 %s（%s，%s）" ;;
        head_progress)        value="第 %s 个容器，共 %s 个" ;;
        head_summary)         value="摘要" ;;
        head_environment)     value="环境" ;;
        head_container)       value="容器 %s" ;;
        head_result)          value="结果" ;;
        col_name)             value="名称" ;;
        col_agent)            value="智能体" ;;
        col_mode)             value="模式" ;;
        col_workspace)        value="工作区" ;;
        col_engine)           value="引擎" ;;
        col_state)            value="状态" ;;
        col_web)              value="Web" ;;
        col_snapshots)        value="快照" ;;
        col_id)               value="ID" ;;
        col_created)          value="创建时间" ;;
        col_label)            value="标签" ;;
        col_size)             value="大小" ;;
        unknown_value)        value="未知" ;;
        dry_write)            value="dry-run：将写入 %s，字段：" ;;
        dry_snapshot_rollback) value="dry-run：回滚 %s 之前会先创建快照" ;;
        dry_url)              value="网址：http://127.0.0.1:%s/" ;;
        prompt_count)         value="要创建几个容器？" ;;
        err_positive_number)  value="需要一个正整数" ;;
        err_unknown_command)  value="未知命令 '%s'（见：install.sh --help）" ;;
        err_unknown_option)   value="未知选项 %s（见：install.sh --help）" ;;
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
        gum_skipped)          value="改用普通提示继续" ;;
        # --- piped, no terminal -------------------------------------------
        pipe_no_tui)          value="install.sh：没有任何改动 —— 本次是非交互运行，无法启动交互式 TUI（stdin 是管道里的脚本）。" ;;
        pipe_run_with_tty)    value="请在有终端的地方运行，或者把子命令通过管道传进去：" ;;
        pipe_or_save)         value="也可以先存下来再用终端运行：" ;;
        # --- container lifecycle ------------------------------------------
        pulling)              value="正在拉取 %s" ;;
        image_refreshed)      value="镜像已刷新：%s（%s）" ;;
        warn_pull_failed)     value="无法刷新 %s（仓库不可达）；改用本地已有的 %s，构建于 %s" ;;
        no_containers_yet)    value="还没有容器；用这条命令创建：%s" ;;
        started)              value="已启动 %s" ;;
        stopped_name)         value="已停止 %s" ;;
        restarted)            value="已重启 %s" ;;
        starting_name)        value="正在启动 %s" ;;
        created_named)        value="已创建 %s（智能体 %s，模式 %s）" ;;
        removed_named)        value="已删除 %s" ;;
        upgraded_named)       value="已将 %s 升级到 %s" ;;
        # --- failures the user has to act on ------------------------------
        err_image_missing)    value="镜像 %s 本地不存在，且给了 --no-pull" ;;
        err_did_not_stay_up)  value="容器 %s 没能保持运行；最近的日志：" ;;
        err_not_running)      value="容器 %s 没有在运行（排障见 docs/containers.md#troubleshooting）" ;;
        err_not_running_try)  value="容器 %s 没有在运行（试试：%s）" ;;
        err_unknown_mode)     value="未知模式 '%s'（应为 persistent 或 ephemeral）" ;;
        err_ephemeral_enter)  value="容器 %s 是 ephemeral 模式创建的，无法进入" ;;
        err_nothing_to_create) value="没有要创建的东西：传 --agent NAME（可选 --name/--count），或用 --file" ;;
        err_no_containers_given) value="没有指定任何容器" ;;
        err_refuse_no_confirm) value="未经确认，拒绝执行；非交互运行请传 --yes 确认" ;;
        err_no_engine_dry)    value="没有找到容器引擎；--dry-run 假定使用 podman" ;;
        warn_already_managed) value="容器 %s 已由本安装器管理；跳过（先删除它才能重建）" ;;
        warn_exists_outside)  value="已存在一个同名但不由本安装器创建的容器 %s；跳过" ;;
        warn_no_engine_dry)   value="没有找到容器引擎；--dry-run 假定使用 podman" ;;
        engine_line)          value="引擎：%s（%s）" ;;
        # --- credentials ---------------------------------------------------
        creds_none)           value="未为 %s 收集凭据：容器仍会创建，但在补上 %s 之前它的智能体无法调用模型；之后可以加到 %s（权限 600）" ;;
        creds_written)        value="已把凭据写入 %s（权限 600）" ;;
        creds_from_env)       value="使用环境变量里的 %s" ;;
        creds_no_tty)         value="没有终端可用于提问：跳过 %s（之后可加到 %s）" ;;
        wrote_file)           value="已写入 %s" ;;
        web_ui_line)          value="Web 界面：install.sh web %s  →  http://127.0.0.1:%s/" ;;
        # --- snapshots and rollback ---------------------------------------
        no_snapshots)         value="%s 还没有快照" ;;
        snapshotting_before_rollback) value="正在回滚前为 %s 创建快照" ;;
        snapshotting_before_fork) value="正在派生之前为 %s 创建快照" ;;
        snapshot_created)     value="已为 %s 创建快照 %s（%s）" ;;
        rolled_back_to)       value="已将 %s 回滚到快照 %s" ;;
        recovered_restart)    value="已恢复 %s（重启了原有容器）" ;;
        recovered_from_snap)  value="已从快照 %s 恢复 %s" ;;
        skip_safety)          value="跳过安全快照（--skip-safety）" ;;
        err_could_not_snapshot) value="无法为 %s 创建快照；容器还在吗？（试试：install.sh recover %s）" ;;
        warn_no_safety_snap)  value="操作前无法为 %s 创建快照；将在没有安全快照的情况下继续" ;;
        warn_snap_before)     value="无法在操作前为 %s 创建快照；将在没有安全快照的情况下继续" ;;
        warn_rebuilt)         value="没有可用快照；%s 已从 %s 重建（home 卷保留）" ;;
        # --- fork ----------------------------------------------------------
        forking)              value="正在从 %s 派生" ;;
        fork_copied_creds)    value="已从 %s 复制凭据；使用前请检查 %s" ;;
        forked_into)          value="已从 %s 派生出 %s（智能体 %s，模式 %s）" ;;
        # --- upgrade -------------------------------------------------------
        kept_volume)          value="保留了卷 %s" ;;
        kept_snapshots_in_use) value="保留了 %s 个仍在使用中镜像的快照：%s" ;;
        kept_snapshots)       value="保留了 %s 的快照，位于 %s" ;;
        # --- doctor --------------------------------------------------------
        doctor_clean)         value="doctor：未发现问题" ;;
        doctor_problems)      value="doctor：发现 %s 个问题" ;;
        doc_no_engine)        value="没有找到容器引擎（安装 podman 或 docker）" ;;
        doc_engine)           value="引擎可用：%s（%s）" ;;
        doc_state_dir)        value="状态目录：%s" ;;
        doc_conf_dir)         value="凭据目录：%s" ;;
        doc_no_containers)    value="还没有管理任何容器" ;;
        doc_engine_missing)   value="引擎 %s 没有安装" ;;
        doc_container_exists) value="容器存在（%s）" ;;
        doc_container_missing) value="容器不见了；运行：install.sh recover %s" ;;
        doc_image_present)    value="镜像存在：%s" ;;
        doc_image_missing)    value="镜像 %s 不存在；运行：install.sh recover %s" ;;
        doc_volume_present)   value="home 卷存在：%s" ;;
        doc_volume_missing)   value="home 卷 %s 不见了" ;;
        doc_creds_ok)         value="凭据 %s（权限 600）" ;;
        doc_creds_mode)       value="凭据 %s 的权限是 %s；应为 600" ;;
        doc_web_ok)           value="Web 界面已发布在 %s" ;;
        doc_web_missing)      value="Web 界面已启用，但没有发布宿主端口；运行：install.sh recover %s" ;;
        doc_snap_ok)          value="快照 %s 的归档可读" ;;
        doc_snap_bad)         value="快照 %s 的归档已损坏：%s" ;;
        # --- web UI --------------------------------------------------------
        warn_web_port_ephemeral) value="ephemeral 容器会忽略 --web-port；它们没有长期运行的 Web 界面" ;;
        web_published)        value="%s 的 Web 界面已发布在 http://127.0.0.1:%s/（容器端口 %s）" ;;
        err_web_ephemeral)    value="'%s' 是 ephemeral 容器；它的 Web 界面会随容器一起退出" ;;
        err_web_no_web)       value="'%s' 是用 --no-web 创建的；要发布 Web 端口请去掉 --no-web 重建" ;;
        err_web_no_port)      value="'%s' 没有发布 Web 端口；升级安装器后重建它（install.sh recover %s）" ;;
        already_running)      value="%s 已经在运行" ;;
        recover_running)      value="%s 正在运行，无需恢复" ;;
        recover_not_staying_up) value="%s 存在但无法保持运行；检查：install.sh logs %s" ;;
        web_already_running)  value="%s 里的 Web 界面已经在运行" ;;
        web_open_url)         value="打开：http://127.0.0.1:%s/?token=%s" ;;
        web_first_visit)      value="首次访问会让该浏览器登录 30 天；之后直接用 http://127.0.0.1:%s/ 就够了" ;;
        web_no_token)         value="日志里还没有启动令牌；它在容器内的 %s" ;;
        # --- snapshots: the home volume ------------------------------------
        snap_no_volume)       value="home 卷 %s 不存在；快照只包含文件系统" ;;
        snap_archived)        value="已把 home 卷归档到 %s/home.tar.gz" ;;
        snap_archive_unreadable) value="home 归档无法读回；已删除它，这样快照 %s 不会悄悄还原一个损坏的 home" ;;
        snap_no_tar)          value="无法归档 %s（镜像里没有 tar？）；快照只包含文件系统" ;;
        snap_no_archive)      value="快照 %s 没有 home 归档；home 卷保持原样" ;;
        snap_archive_bad)     value="快照 %s 的 home 归档无法读取（%s/home.tar.gz）；没有任何改动" ;;
        snap_archive_bad2)    value="快照 %s 的 home 归档无法读取（%s）；没有任何改动" ;;
        snap_image_gone)      value="快照镜像 %s 已不存在；快照 %s 无法还原" ;;
        home_restored)        value="已从快照 %s 还原 home 卷（%s 个条目）" ;;
        # --- fork: copying the home volume ---------------------------------
        forking_copy_snap)    value="正在从快照 %s 复制 home 卷" ;;
        forking_copy_live)    value="正在复制使用中的 home 卷 %s" ;;
        # --- errors and confirmations --------------------------------------
        err_no_such_container) value="本安装器没有管理名为 '%s' 的容器（试试：install.sh list）" ;;
        err_pull_failed)      value="无法拉取 %s" ;;
        err_no_web_ui)        value="本安装器不知道该怎样为智能体 '%s' 打开 Web 界面" ;;
        err_start_it)         value="容器 %s 没有在运行；用这条命令启动：install.sh start %s" ;;
        err_no_snapshot)      value="%s 没有可用快照（运行：install.sh snapshot %s）" ;;
        err_snapshot_not_found) value="%s 找不到快照 %s" ;;
        err_invalid_name)     value="容器名 '%s' 无效" ;;
        err_name_exists)      value="容器 %s 已经存在" ;;
        err_unknown_agent)    value="未知的智能体 '%s'" ;;
        err_decl_missing)     value="声明文件 %s 不存在" ;;
        err_fork_args)        value="fork 需要源容器和目标名：install.sh fork SRC NEW" ;;
        warn_menu_selection)  value="无法识别的菜单选择：'%s'（key='%s'）" ;;
        err_volume_exists)    value="卷 %s 已经存在" ;;
        warn_both_engines)    value="podman 和 docker 都已安装；使用 %s（可用 --engine 覆盖）" ;;
        err_engine_required)  value="这个容器需要容器引擎 %s，但它没有安装" ;;
        kept_image_in_use)    value="保留镜像 %s：容器 %s 正从它运行（删掉那个容器后再清理镜像）" ;;
        kept_snapshot_in_use) value="%s 的快照 %s 仍被 %s 使用；保留它及其镜像 %s" ;;
        image_undeletable)    value="镜像 %s 无法删除（可能仍在使用）；保留快照 %s" ;;
        # --- gum (the rich TUI) --------------------------------------------
        gum_explain)          value="gum（charmbracelet）负责渲染交互界面，但当前没有安装。" ;;
        gum_missing)          value="没有安装 gum；改用朴素提示继续" ;;
        gum_install_failed)   value="无法安装 gum；改用朴素提示继续" ;;
        gum_no_build)         value="%s 没有对应的 gum 构建" ;;
        gum_installed)        value="已把 gum %s 安装到 %s/.local/bin/gum" ;;
        gum_install_prompt)   value="要现在装到 %s/.local/bin 吗？[Y/n] " ;;
        aborted)              value="已中止" ;;
        cancelled)            value="已取消" ;;
        confirm_create)       value="创建这些容器吗？" ;;
        confirm_rollback)     value="把容器 %s 替换为快照 %s 吗？" ;;
        confirm_upgrade)      value="把 %s 升级到 %s 吗？会先创建一个快照。" ;;
        confirm_remove)       value="删除容器 %s 及其卷吗？" ;;
        prompt_agent_for)     value="第 %s 个容器用哪个智能体" ;;
        prompt_name)          value="容器名" ;;
        prompt_lifecycle)     value="%s 的生命周期" ;;
        prompt_workspace)     value="挂载到 /workspace 的宿主目录" ;;
        mode_persistent_desc) value="persistent —— 一个持续运行的系统；状态保存在命名卷里" ;;
        mode_ephemeral_desc)  value="ephemeral —— 运行一次智能体，退出后容器即被删除" ;;
        *) value="" ;;
      esac
      ;;
    *)
      case "$key" in
        tui_title)            value="agent-workspace — containers for coding agents" ;;
        tui_subtitle)         value="pick an action, or press q to quit" ;;
        # --- section headings and table headers ---------------------------
        head_new_containers)  value="New agent containers" ;;
        head_creating)        value="Creating %s (%s, %s)" ;;
        head_progress)        value="Container %s of %s" ;;
        head_summary)         value="Summary" ;;
        head_environment)     value="Environment" ;;
        head_container)       value="Container %s" ;;
        head_result)          value="Result" ;;
        col_name)             value="NAME" ;;
        col_agent)            value="AGENT" ;;
        col_mode)             value="MODE" ;;
        col_workspace)        value="WORKSPACE" ;;
        col_engine)           value="ENGINE" ;;
        col_state)            value="STATE" ;;
        col_web)              value="WEB" ;;
        col_snapshots)        value="SNAPSHOTS" ;;
        col_id)               value="ID" ;;
        col_created)          value="CREATED" ;;
        col_label)            value="LABEL" ;;
        col_size)             value="SIZE" ;;
        unknown_value)        value="unknown" ;;
        dry_write)            value="dry-run: would write %s with" ;;
        dry_snapshot_rollback) value="dry-run: would snapshot %s before rolling it back" ;;
        dry_url)              value="url: http://127.0.0.1:%s/" ;;
        prompt_count)         value="How many containers?" ;;
        err_positive_number)  value="expected a positive number" ;;
        err_unknown_command)  value="unknown command '%s' (see: install.sh --help)" ;;
        err_unknown_option)   value="unknown option %s (see: install.sh --help)" ;;
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
        gum_skipped)          value="continuing with plain prompts" ;;
        pipe_no_tui)          value="install.sh: nothing was changed - this ran non-interactively, so the interactive TUI could not start (stdin is the piped script)." ;;
        pipe_run_with_tty)    value="Run it with a terminal, or pass a subcommand through the pipe:" ;;
        pipe_or_save)         value="Or save it first and run it with a terminal:" ;;
        # --- container lifecycle ------------------------------------------
        pulling)              value="pulling %s" ;;
        image_refreshed)      value="refreshed image %s (%s)" ;;
        warn_pull_failed)     value="could not refresh %s (registry unreachable); using the local copy %s, built %s" ;;
        no_containers_yet)    value="no containers yet; create one with: %s" ;;
        started)              value="started %s" ;;
        stopped_name)         value="stopped %s" ;;
        restarted)            value="restarted %s" ;;
        starting_name)        value="starting %s" ;;
        created_named)        value="created %s (agent %s, mode %s)" ;;
        removed_named)        value="removed %s" ;;
        upgraded_named)       value="upgraded %s to %s" ;;
        # --- failures the user has to act on ------------------------------
        err_image_missing)    value="image %s is not available locally and --no-pull was given" ;;
        err_did_not_stay_up)  value="container %s did not stay up; recent log lines:" ;;
        err_not_running)      value="container %s is not running (docs/containers.md#troubleshooting explains host limits)" ;;
        err_not_running_try)  value="container %s is not running (try: %s)" ;;
        err_unknown_mode)     value="unknown mode '%s' (expected persistent or ephemeral)" ;;
        err_ephemeral_enter)  value="container %s was created in ephemeral mode and cannot be entered" ;;
        err_nothing_to_create) value="nothing to create: pass --agent NAME (and optionally --name/--count), or use --file" ;;
        err_no_containers_given) value="no containers were specified" ;;
        err_refuse_no_confirm) value="refusing to act without confirmation; pass --yes to confirm a non-interactive run" ;;
        err_no_engine_dry)    value="no container engine found; --dry-run assumes podman" ;;
        warn_already_managed) value="container %s is already managed; skipping (remove it first to recreate)" ;;
        warn_exists_outside)  value="a container named %s already exists outside this installer; skipping" ;;
        warn_no_engine_dry)   value="no container engine found; --dry-run assumes podman" ;;
        engine_line)          value="engine: %s (%s)" ;;
        # --- credentials ---------------------------------------------------
        creds_none)           value="no credentials collected for %s: the container is still created, but its agent cannot reach a model until %s is in place; add it later to %s (mode 600)" ;;
        creds_written)        value="wrote credentials to %s (mode 600)" ;;
        creds_from_env)       value="using %s from the environment" ;;
        creds_no_tty)         value="no terminal for prompts: skipping %s (add it later to %s)" ;;
        wrote_file)           value="wrote %s" ;;
        web_ui_line)          value="web UI: install.sh web %s  →  http://127.0.0.1:%s/" ;;
        # --- snapshots and rollback ---------------------------------------
        no_snapshots)         value="no snapshots for %s" ;;
        snapshotting_before_rollback) value="snapshotting %s before the rollback" ;;
        snapshotting_before_fork) value="snapshotting %s before the fork" ;;
        snapshot_created)     value="snapshot %s of %s (%s)" ;;
        rolled_back_to)       value="rolled %s back to snapshot %s" ;;
        recovered_restart)    value="recovered %s (restarted the existing container)" ;;
        recovered_from_snap)  value="recovered %s from snapshot %s" ;;
        skip_safety)          value="skipping the safety snapshot (--skip-safety)" ;;
        err_could_not_snapshot) value="could not snapshot %s; is the container present? (try: install.sh recover %s)" ;;
        warn_no_safety_snap)  value="could not snapshot %s before this operation; continuing without a safety snapshot" ;;
        warn_snap_before)     value="could not snapshot %s before this operation; continuing without a safety snapshot" ;;
        warn_rebuilt)         value="no snapshot was available; %s was rebuilt from %s (the home volume is kept)" ;;
        # --- fork ----------------------------------------------------------
        forking)              value="forking %s" ;;
        fork_copied_creds)    value="copied credentials from %s; review %s before use" ;;
        forked_into)          value="forked %s into %s (agent %s, mode %s)" ;;
        # --- upgrade -------------------------------------------------------
        kept_volume)          value="kept volume %s" ;;
        kept_snapshots_in_use) value="kept %s snapshot(s) whose image is still in use: %s" ;;
        kept_snapshots)       value="kept snapshots for %s in %s" ;;
        # --- doctor --------------------------------------------------------
        doctor_clean)         value="doctor: no problems found" ;;
        doctor_problems)      value="doctor: %s problem(s) found" ;;
        doc_no_engine)        value="no container engine found (install podman or docker)" ;;
        doc_engine)           value="engine available: %s (%s)" ;;
        doc_state_dir)        value="state directory: %s" ;;
        doc_conf_dir)         value="credentials directory: %s" ;;
        doc_no_containers)    value="no containers managed yet" ;;
        doc_engine_missing)   value="engine %s is not installed" ;;
        doc_container_exists) value="container exists (%s)" ;;
        doc_container_missing) value="container is missing; run: install.sh recover %s" ;;
        doc_image_present)    value="image present: %s" ;;
        doc_image_missing)    value="image %s is not present; run: install.sh recover %s" ;;
        doc_volume_present)   value="home volume present: %s" ;;
        doc_volume_missing)   value="home volume %s is missing" ;;
        doc_creds_ok)         value="credentials %s (mode 600)" ;;
        doc_creds_mode)       value="credentials %s have mode %s; expected 600" ;;
        doc_web_ok)           value="web UI published on %s" ;;
        doc_web_missing)      value="web UI is enabled but no host port is published; run: install.sh recover %s" ;;
        doc_snap_ok)          value="snapshot %s archive readable" ;;
        doc_snap_bad)         value="snapshot %s archive is corrupt: %s" ;;
        # --- web UI --------------------------------------------------------
        warn_web_port_ephemeral) value="--web-port is ignored for ephemeral containers; they have no long-running web UI" ;;
        web_published)        value="%s web UI is published on http://127.0.0.1:%s/ (container port %s)" ;;
        err_web_ephemeral)    value="'%s' is an ephemeral container; its web UI would exit with the container" ;;
        err_web_no_web)       value="'%s' was created with --no-web; recreate it without --no-web to publish a web port" ;;
        err_web_no_port)      value="'%s' publishes no web port; recreate it (install.sh recover %s) after upgrading the installer" ;;
        already_running)      value="%s is already running" ;;
        recover_running)      value="%s is running; nothing to recover" ;;
        recover_not_staying_up) value="%s exists but does not stay up; check: install.sh logs %s" ;;
        web_already_running)  value="the web UI is already running in %s" ;;
        web_open_url)         value="open: http://127.0.0.1:%s/?token=%s" ;;
        web_first_visit)      value="the first visit signs that browser in for 30 days; afterwards http://127.0.0.1:%s/ is enough" ;;
        web_no_token)         value="no launch token in the log yet; inside the container it is %s" ;;
        # --- snapshots: the home volume ------------------------------------
        snap_no_volume)       value="home volume %s does not exist; the snapshot holds the filesystem only" ;;
        snap_archived)        value="archived the home volume into %s/home.tar.gz" ;;
        snap_archive_unreadable) value="the home archive could not be read back; deleted it so snapshot %s cannot silently restore a broken home" ;;
        snap_no_tar)          value="could not archive %s (no tar in the image?); the snapshot holds the filesystem only" ;;
        snap_no_archive)      value="snapshot %s has no home archive; the home volume is left as it is" ;;
        snap_archive_bad)     value="the home archive of snapshot %s is unreadable (%s/home.tar.gz); nothing was changed" ;;
        snap_archive_bad2)    value="the home archive of snapshot %s is unreadable (%s); nothing was changed" ;;
        snap_image_gone)      value="snapshot image %s is gone; snapshot %s cannot be restored" ;;
        home_restored)        value="restored the home volume from snapshot %s (%s entries)" ;;
        # --- fork: copying the home volume ---------------------------------
        forking_copy_snap)    value="copying the home volume from snapshot %s" ;;
        forking_copy_live)    value="copying the live home volume %s" ;;
        # --- errors and confirmations --------------------------------------
        err_no_such_container) value="no container named '%s' is managed by this installer (try: install.sh list)" ;;
        err_pull_failed)      value="could not pull %s" ;;
        err_no_web_ui)        value="no web UI this installer knows how to open for agent '%s'" ;;
        err_start_it)         value="container %s is not running; start it with: install.sh start %s" ;;
        err_no_snapshot)      value="no snapshot available for %s (run: install.sh snapshot %s)" ;;
        err_snapshot_not_found) value="snapshot %s not found for %s" ;;
        err_invalid_name)     value="invalid container name '%s'" ;;
        err_name_exists)      value="container %s already exists" ;;
        err_unknown_agent)    value="unknown agent '%s'" ;;
        err_decl_missing)     value="declaration file %s does not exist" ;;
        err_fork_args)        value="fork needs a source and a destination: install.sh fork SRC NEW" ;;
        warn_menu_selection)  value="unrecognised menu selection: '%s' (key='%s')" ;;
        err_volume_exists)    value="volume %s already exists" ;;
        warn_both_engines)    value="both podman and docker are installed; using %s (override with --engine)" ;;
        err_engine_required)  value="container engine %s is required for this container but is not installed" ;;
        kept_image_in_use)    value="keeping image %s: container %s runs from it (remove that container, then prune images)" ;;
        kept_snapshot_in_use) value="snapshot %s of %s is still used by %s; keeping it and its image %s" ;;
        image_undeletable)    value="image %s could not be removed (it may still be in use); keeping snapshot %s" ;;
        # --- gum (the rich TUI) --------------------------------------------
        gum_explain)          value="gum (charmbracelet) renders the interactive interface and is not installed." ;;
        gum_missing)          value="gum is not installed; continuing with plain prompts" ;;
        gum_install_failed)   value="could not install gum; continuing with plain prompts" ;;
        gum_no_build)         value="no gum build for %s" ;;
        gum_installed)        value="installed gum %s to %s/.local/bin/gum" ;;
        gum_install_prompt)   value="Install it into %s/.local/bin now? [Y/n] " ;;
        aborted)              value="aborted" ;;
        cancelled)            value="cancelled" ;;
        confirm_create)       value="Create these containers?" ;;
        confirm_rollback)     value="Replace container %s with snapshot %s?" ;;
        confirm_upgrade)      value="Upgrade %s to %s? A snapshot is taken first." ;;
        confirm_remove)       value="Remove container %s and its volume?" ;;
        prompt_agent_for)     value="Agent for container %s" ;;
        prompt_name)          value="Container name" ;;
        prompt_lifecycle)     value="Lifecycle for %s" ;;
        prompt_workspace)     value="Host directory mounted at /workspace" ;;
        mode_persistent_desc) value="persistent — a running system; state lives in a named volume" ;;
        mode_ephemeral_desc)  value="ephemeral — run the agent once, the container is removed on exit" ;;
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

# usage_text: the whole --help block.
#
# This is the one message stored as a block instead of as keys. The usage text is
# a table whose left column is the command and flag surface itself -- `create`,
# `--dry-run, -n`, `./install.sh rollback NAME [--to ID]` -- and that column must
# be byte-identical in every language, because it is what people copy and what
# tests/contract.sh asserts entry by entry. Splitting it into ~60 keys would put
# the command names in the catalogue as well, where a translator could quietly
# rename one. Keeping the block whole makes the invariant structural: only the
# descriptions to the right of the column change.
#
# The heredocs stay quoted so `$XDG_DATA_HOME` and `$XDG_CONFIG_HOME` are printed
# literally -- they are documentation of the paths, not values to expand.
usage_text() {
  case "$AW_LANG" in
    zh)
      cat <<'USAGE'
agent-workspace installer（安装器）

  ./install.sh                 打开交互式 TUI（本项目的常规用法：选择智能体、
                               给容器命名、挑一个生命周期，然后创建）
  ./install.sh create [opts]   不用 TUI，直接创建容器
  ./install.sh list            列出本安装器创建的容器
  ./install.sh enter NAME      交互式运行容器里的智能体
  ./install.sh shell NAME      在容器里打开一个登录 shell
  ./install.sh web NAME        启动智能体的 Web 界面并打印宿主上的网址
  ./install.sh logs NAME       显示容器日志
  ./install.sh start|stop|restart NAME
  ./install.sh snapshot NAME [--label TEXT] [--keep N]
                               提交文件系统，并把 home 卷归档进快照
  ./install.sh snapshots NAME  列出某个容器的快照
  ./install.sh rollback NAME [--to ID]
                               用一个快照替换当前容器
  ./install.sh recover NAME    重建丢失或已停止的容器
  ./install.sh fork SRC NEW [--agent A] [--mode M] [--workspace DIR] [--from ID] [--live]
                               从已有容器派生出一个新容器
  ./install.sh upgrade NAME [--image REF]
                               把容器迁移到更新的镜像（会先创建快照）
  ./install.sh remove NAME...  删除容器（加 --purge-snapshots 连快照一起删）
  ./install.sh doctor [--strict]
                               检查引擎、容器、卷与凭据

create 选项
  --agent NAME        要运行的智能体（见：install.sh create --help-agents）
  --name NAME         容器名（默认：<agent>-box）
  --count N           创建 N 个容器（N > 1 时依次命名为 NAME-1..NAME-N）
  --mode MODE         persistent（systemd，保留状态）或 ephemeral（只运行一次）
  --workspace DIR     挂载到 /workspace 的宿主目录
  --env KEY=VALUE     传给容器的额外环境变量
  --file FILE         从声明文件读取（'-' 表示 stdin）：
                        name agent [mode] [workspace]
  --save FILE         把创建出来的容器按同样格式写回该文件

智能体 Web 界面的 create 选项
  --web-port N        要发布的宿主回环端口（默认：3080 起的第一个空闲端口）
  --no-web            不为这些容器发布 Web 端口

全局选项
  --engine auto|podman|docker   用哪个引擎（默认：auto）
  --image REF                   要运行的镜像（默认：取自 image.env）
  --no-tui                      绝不启动 TUI；该提问时直接失败
  --dry-run, -n                 只打印引擎命令，不真正执行
  --no-pull                     不刷新镜像：直接用本地已有的副本
  --yes, -y                     所有确认都视为「是」
  --quiet, -q                   只打印警告和错误
  --strict                      doctor 专用：任何问题都以非零码退出
  --keep N                      快照专用：只保留最新的 N 个快照（默认 5）
  --purge-snapshots             remove 时：连快照一起删除
  --keep-volume                 remove 时：保留 home 卷
  --skip-safety                 rollback 时：不先给容器做快照
  --follow, -f / --tail N       logs 时：跟踪日志／只显示最后 N 行
  --help-agents                 列出本次构建提供的智能体
  --help, -h                    显示本帮助

宿主路径
  容器与快照：  $XDG_DATA_HOME（默认 ~/.local/share）/agent-workspace
  凭据（权限 600）：  $XDG_CONFIG_HOME（默认 ~/.config）/agent-workspace/containers
USAGE
      ;;
    *)
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
  --no-pull                     do not refresh the image; use the local copy
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
      ;;
  esac
}
