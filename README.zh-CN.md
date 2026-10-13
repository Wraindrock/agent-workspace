# agent-workspace

一个**声明式、可回滚的 Fedora bootc 系统容器**，专门用来运行 Coding agent
或通用型 agent。整个镜像的构建过程由仓库内的声明文件描述，每个部分都能单独
开关，任何一台主机都能原子回滚。

- **bootc / OCI 原生**：操作系统*就是*镜像。`bootc switch` 前进，`bootc rollback`
  后退，不需要重装、也不会出现配置漂移。
- **声明式**：模块与 agent 在 `config/` 里声明，参数在 `image.env` 里声明；
  构建读取这些文件，你永远不用手工改一台活着的机器。
- **模块化**：九个按顺序执行的构建模块，每个都有开关，每个都会被记录进镜像
  自己的 manifest。
- **开箱即用**：podman、git、node、python、常用 shell 工具链以及一组 agent
  CLI，已经预配置好并支持 rootless 运行。
- **MIT 协议**：构建脚本、配置与 CLI 全部开源，随意 fork。

## 快速开始

### 在支持 bootc 的机器上（推荐）

~~~bash
sudo bootc switch --transport registry ghcr.io/wraindrock/agent-workspace:latest
sudo systemctl reboot
~~~

重启后 `agent-workspace` 就在 `PATH` 里：

~~~bash
agent-workspace version      # 这个镜像是什么
agent-workspace manifest     # 它是怎么被构建出来的（逐模块）
agent-workspace doctor       # 运行中的系统是否兑现了镜像的承诺
agent-workspace rollback     # 随时原子回滚
~~~

### 当作隔离 agent 的系统容器运行

这是一套**完整的操作系统**，不是精简的应用镜像：Fedora bootc，有自己的 PID 1、
systemd、用户、软件包数据库和 SELinux 策略。用 podman 跑起来，每个 agent 都独占
一整个操作系统——一次 `npm install -g`、一次 `dnf install`、一个误删的目录或一份
写坏的配置，都留在那个容器里：

~~~bash
# 一个 agent 独占一套系统，代码挂载到 /workspace
podman run --rm -it \
  -v "$PWD:/workspace:z" --workdir /workspace \
  ghcr.io/wraindrock/agent-workspace:latest claude

# 镜像内置多个 harness，换一个名字即可
podman run --rm -it -v "$PWD:/workspace:z" --workdir /workspace \
  ghcr.io/wraindrock/agent-workspace:latest codex

# 不挂载目录，agent 就在一次性的文件系统里工作
podman run --rm -it --entrypoint /bin/bash \
  ghcr.io/wraindrock/agent-workspace:latest
~~~

请用 **rootless** 方式运行（`podman`，而不是 `sudo podman`）：此时容器里的 root 就是
你在主机上的用户，agent 写入 `/workspace` 的文件归属你本人。在已启动的裸机/虚拟机
上，镜像还会在首次开机时创建非特权用户 `agent`。

把仓库克隆下来，同样的命令只差一个 recipe：

~~~bash
just build                # 在本地构建镜像
just sandbox              # 用 claude 跑当前目录，系统用完即弃
just sandbox codex        # 换一个 harness
just sandbox /bin/bash    # 只进沙箱里要一个 shell
~~~

想让 systemd 与完整系统在沙箱里跑起来？保留默认入口点，然后 exec 进去：

~~~bash
podman run -d --name agent-box -v "$PWD:/workspace:z" \
  ghcr.io/wraindrock/agent-workspace:latest
podman exec -it agent-box /bin/bash
~~~

生命周期命令（`switch` / `rollback` / `update` / `pin`）会检测到自己处在容器里并
礼貌拒绝，而不是执行到一半才失败。

### 用 ISO 或虚拟机镜像安装

从最新的 build-disk workflow 产物里下载 qcow2 或 Anaconda ISO，启动后安装器
会铺下同一个镜像。自己构建：

~~~bash
just build-qcow2   # ./output/*.qcow2
just build-iso     # ./output/*.iso
just run-vm        # 在 qemu 里启动 qcow2
~~~

## “声明式”在这里的含义

三个文件描述一切，镜像自己会证明它符合这些描述：

| 文件 | 声明内容 |
| --- | --- |
| `image.env` | 镜像身份：名称、组织、描述、默认 tag、基础镜像、agent 用户名 |
| `config/modules.conf` | 哪些构建模块参与（`20-container-tools=1`、`40-agent-harnesses=0` ……） |
| `config/agents.conf` | 安装哪些 agent（`claude-code=1`、`aider=0` ……） |

构建时，pipeline 会在**镜像内**写入 `/usr/share/agent-workspace/manifest.json`，
记录执行过的模块、安装的 agent、工具链版本以及精确的基础镜像。在已部署的主机上：

~~~bash
agent-workspace manifest | jq '.modules, .agents, .baseImage'
~~~

如果机器与自己的 manifest 不一致，`agent-workspace doctor --strict` 会返回非零
退出码——每日健康检查定时器跑的就是它。

## 模块

模块按目录名前缀顺序执行。`build_files/modules/` 下每个目录包含一个
`module.env`（名称、描述、默认状态）和一个 `install.sh`。

| 模块 | 内容 |
| --- | --- |
| `00-preflight` | 校验构建环境，记录基础镜像与 Fedora 版本 |
| `10-base-packages` | git、git-lfs、curl、jq、rsync、ssh 客户端与基础网络/归档工具 |
| `20-container-tools` | podman、buildah、skopeo、crun、netavark、passt、`podman.socket`、sub-id 区间 |
| `30-agent-toolchains` | gcc/make、gh、just、Node.js + pnpm/tsx/typescript、Python + pipx、uv |
| `40-agent-harnesses` | 依据 `config/agents.conf` 选择安装的 agent CLI |
| `50-devtools` | neovim、ripgrep、tmux、shellcheck、direnv 等日常工具 |
| `60-system-config` | systemd 单元、sysctl 调优、registries 配置、`/etc/skel` |
| `80-manifest` | 写出镜像 manifest 与模块清单 |
| `90-cleanup` | 清理缓存与日志，保持镜像精简 |

模块契约与新增模块的方法见 [docs/modules.md](docs/modules.md)。

## Agent

`config/agents.conf` 决定镜像里装哪些 agent，配方位于
`build_files/modules/40-agent-harnesses/agents/`。默认启用 Claude Code、Codex CLI
与 Gemini CLI，另外提供 OpenCode 与 Aider 配方。详情见
[docs/agents.md](docs/agents.md)。

## 回滚、切换与固定

~~~bash
agent-workspace update            # 拉取当前 tag 的最新构建并暂存
sudo systemctl reboot            # 启动它
agent-workspace rollback         # 回到上一个部署
agent-workspace switch 20261013  # 切到某个日期构建
agent-workspace pin              # 把本机固定到当前启动的 digest
agent-workspace pin --clear      # 解除固定
~~~

每次发布都会同时推送 `:previous`，因此运维也可以用单个 tag 把整个机群往回搬。
细节见 [docs/rollback.md](docs/rollback.md)。

## 校验镜像

镜像使用 [cosign](https://docs.sigstore.dev/) 签名。默认走 GitHub OIDC 的
keyless 签名；如果你更信任固定公钥，运行 `just cosign-keygen` 并把私钥存为
仓库 secret `SIGNING_SECRET`，工作流会自动切换到密钥签名。

## 目录结构

~~~text
Containerfile            构建契约：context 阶段 + 镜像阶段
image.env                镜像身份与构建参数
build_files/             模块化的构建脚本（build.sh + lib/ + modules/）
config/                  声明式开关：modules.conf、agents.conf
system_files/            原样覆盖到 / 的文件（systemd、sysctl、profile.d）
runtime/                 镜像内的 agent-workspace CLI
scripts/                 宿主机侧的 switch / rollback / doctor / cosign 脚本
disk_config/             磁盘布局与安装器定制
tests/                   lint.sh、smoke.sh
docs/                    架构、模块、agent、回滚文档
~~~

完整设计说明见 [docs/architecture.md](docs/architecture.md)。

## 注意事项

- GHCR 上的 package 在首次推送后**默认是 private**。若希望匿名 `podman pull` 或
  `bootc switch`，请在 *Packages -> agent-workspace -> Package settings ->
  Change visibility* 中改为 public。
- 默认基础镜像是 `ghcr.io/ublue-os/base-main:latest`（Fedora + bootc，无桌面）。
  桌面用户可把 `BASE_IMAGE` 换成 `ghcr.io/ublue-os/bluefin:stable` 或
  `ghcr.io/ublue-os/aurora:stable`；极简用户可用 `quay.io/fedora/fedora-bootc:44`。
- 构建磁盘镜像与本地跑虚拟机需要 root 与 KVM；CI 里由 `build-disk` 工作流负责。

## 许可证

[MIT](LICENSE) (c) 2026 Wraindrock。
