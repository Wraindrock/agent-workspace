# agent-workspace

**给 coding agent 用的一次性操作系统。** `install.sh` 问你几个问题，就在你的 Linux
机器上创建容器：每个容器都是一套完整、预配置好的 Fedora bootc 系统，里面装着
你选的那个 agent。

- **只有一个入口**：`./install.sh` 的交互式 TUI。不用写 manifest，不用背
  `docker run` 参数，也不需要 root。
- **一个 agent 独占一套系统**：自己的 PID 1、systemd、用户、软件包数据库与
  SELinux 策略，所以 `dnf install`、`npm install -g` 或一次误删都留在容器里。
- **快照与回滚**：给容器打快照、回滚、事故后恢复，或者分叉出第二个容器：
  [docs/rollback.md](docs/rollback.md)。
- **声明式构建**：镜像由 `image.env`、`config/modules.conf`、`config/agents.conf`
  描述；模块与 agent 都有开关，镜像会把自己的组成写进 manifest。
- **MIT 协议**：构建脚本、配置与安装器全部开源，随意 fork。

## 快速开始

~~~bash
git clone https://github.com/wraindrock/agent-workspace
cd agent-workspace
./install.sh
~~~

TUI 会依次问你：容器里装哪个 agent、容器叫什么名字、生命周期选 **persistent**
（systemd 常驻，home 卷跨重启保留）还是 **ephemeral**（跑完即弃）、把主机上哪个
目录挂载到 `/workspace`，以及那个 agent 需要的凭据。之后它创建好容器，并告诉你
怎么进去。

~~~bash
./install.sh list              # 这台机器上已经有什么
./install.sh enter dsh-box     # 在它自己的系统里运行 agent
./install.sh --help            # 所有子命令，含非交互用法
~~~

**使用**本项目只需要这个脚本，仓库其余部分是给你构建自己的镜像用的。容器完整
参考：[docs/containers.md](docs/containers.md)。

### 不用安装器的手动方式

同一个镜像也可以只用来跑一次性的沙箱：

~~~bash
podman run --rm -it -v "$PWD:/workspace:z" --workdir /workspace \
  ghcr.io/wraindrock/agent-workspace:latest dsh
~~~

请用 **rootless** 方式运行（`podman`，而不是 `sudo podman`），这样 agent 写入
`/workspace` 的文件归属你本人。install.sh 已经替你做好了这件事：home 目录放在
命名卷里，你选的目录挂载到 `/workspace`。

### 在支持 bootc 的机器上（进阶、可选）

镜像本身是 bootc 镜像，所以也可以直接当作一台自有机器的操作系统：

~~~bash
sudo bootc switch --transport registry ghcr.io/wraindrock/agent-workspace:latest
sudo systemctl reboot
~~~

这与本项目的主要用法不同：下面那些容器生命周期命令对这样安装的机器不适用。
在任何正在运行的实例里，镜像自带的 CLI 会告诉你它是什么：

~~~bash
agent-workspace version      # 这个镜像是什么
agent-workspace manifest     # 它是怎么被构建出来的（逐模块）
agent-workspace doctor       # 运行中的系统是否兑现了镜像的承诺
~~~

默认镜像内置两个 harness，DSH 与 OpenCode：

~~~bash
# 一个 agent 独占一套系统，代码挂载到 /workspace
podman run --rm -it -v "$PWD:/workspace:z" --workdir /workspace \
  ghcr.io/wraindrock/agent-workspace:latest dsh

# 换另一个内置 harness
podman run --rm -it -v "$PWD:/workspace:z" --workdir /workspace \
  ghcr.io/wraindrock/agent-workspace:latest opencode

# systemd 是 PID 1，因此常驻容器可以像一台机器一样进去
podman run -d --name agent-box -v "$PWD:/workspace:z" --systemd=always \
  ghcr.io/wraindrock/agent-workspace:latest
podman exec -it agent-box /bin/bash
~~~

任何实例首次启动时，镜像会创建非特权用户 `agent`，由它持有 agent 工作区
（见[首次开机](#首次开机)）。

## “声明式”在这里的含义

三个文件描述一切，镜像自己会证明它符合这些描述：

| 文件 | 声明内容 |
| --- | --- |
| `image.env` | 镜像身份：名称、组织、描述、默认 tag、基础镜像、agent 用户名 |
| `config/modules.conf` | 哪些构建模块参与（`20-container-tools=1`、`40-agent-harnesses=0` ……） |
| `config/agents.conf` | 安装哪些 agent（`dsh=1`、`opencode=1` ……） |

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
| `50-devtools` | neovim、ripgrep、tmux、tree、zsh、fd、git-delta、htop、shellcheck、direnv |
| `60-system-config` | systemd 单元、sysctl 调优、registries 配置、`/etc/skel` |
| `80-manifest` | 写出镜像 manifest 与模块清单 |
| `90-cleanup` | 清理缓存与日志，保持镜像精简 |

模块契约与新增模块的方法见 [docs/modules.md](docs/modules.md)。

## Agent

`config/agents.conf` 决定镜像里装哪些 agent，配方位于
`build_files/modules/40-agent-harnesses/agents/`。默认启用 **DSH（DeepSeek Harness）**
与 **OpenCode**；Claude Code、Codex CLI、Gemini CLI、Aider 的配方也都在，把对应的一行
改成 `1` 就会装进镜像。镜像会把自己支持的 agent 写进 manifest（`agentCatalog`），
`install.sh` 据此生成菜单。详情见 [docs/agents.md](docs/agents.md)。

## 管理容器

安装器就是接口：可以交互，也可以一个动作一条子命令。

~~~bash
./install.sh create --agent dsh --name dsh-box --workspace "$PWD"
./install.sh list
./install.sh snapshot dsh-box --label before-refactor
./install.sh rollback dsh-box
./install.sh fork dsh-box dsh-experiment
./install.sh doctor --strict
~~~

整组容器也可以写成声明文件，非交互地创建：

~~~
# name       agent     lifecycle   workspace
review-box   dsh       persistent  ~/work/review
scratch      opencode  ephemeral
~~~

~~~bash
./install.sh create --file containers.conf --dry-run   # 只打印引擎命令
./install.sh create --file containers.conf --save saved.conf
~~~

`persistent` 容器以 systemd 常驻、`/home/agent` 落在命名卷里、可跨重启；`ephemeral`
只跑一条命令，退出即删除。agent 菜单直接读镜像自己的 manifest，所以永远与构建一致。
完整说明见 [docs/containers.md](docs/containers.md)。

## 在宿主机打开 agent 的 web UI

DeepSeek Harness 自带 web UI。容器只把它绑在自己的回环上，安装器把它发布到你的回环：

~~~bash
./install.sh web dsh-box
~~~

该命令在容器内以 agent 用户启动 `dsh web`，等它起来后打印一个一次性链接：

~~~
✓ dsh web UI is published on http://127.0.0.1:34700/ (container port 3080)
  open this once: http://127.0.0.1:34700/?token=...
~~~

第一次访问会在浏览器里写入 30 天有效的 cookie，因此 token 只需要用一次。宿主端口在
创建容器时选定并跟容器一起记录，所以 `rollback`、`recover`、`upgrade` 都沿用同一个
地址，`fork` 出的新容器会另行分配。`./install.sh create --web-port 8080` 可以自己指定
端口，`--no-web` 则完全不发布端口。映射始终是 `127.0.0.1:<宿主端口>:3080`，从网络上
访问不到。细节见 [docs/containers.md](docs/containers.md)。

## 快照、回滚与分叉

回滚的单位是容器，不是你的宿主系统：

~~~bash
./install.sh snapshot dsh-box              # 提交文件系统并归档 /home/agent
./install.sh rollback dsh-box              # 回到最新快照（也可 --to ID）
./install.sh recover dsh-box               # 重启、还原或重建丢掉的容器
./install.sh fork dsh-box dsh-experiment   # 从现有容器分叉出第二个
./install.sh upgrade dsh-box --image ghcr.io/wraindrock/agent-workspace:latest
~~~

`upgrade` 会先打一个 `pre-upgrade` 快照，所以镜像出问题只差一次 `rollback`；
`fork` 默认也先给来源容器打快照（除非传 `--live`）。保留策略、精确语义以及
*不在*覆盖范围内的东西见 [docs/rollback.md](docs/rollback.md)。

## 校验镜像

镜像使用 [cosign](https://docs.sigstore.dev/) 签名。默认走 GitHub OIDC 的
keyless 签名；如果你更信任固定公钥，运行 `just cosign-keygen` 并把私钥存为
仓库 secret `SIGNING_SECRET`，工作流会自动切换到密钥签名。

## 自己构建镜像

~~~bash
git clone https://github.com/wraindrock/agent-workspace
cd agent-workspace
just check     # 仓库自检，不需要 podman
just build     # 用 podman 构建镜像
just verify    # 构建 + 容器自检
~~~

依赖：`podman`（或 `docker`）与 `just`，运行 `install.sh` 另需 bash 4.4+。
仓库自检在装了 `shellcheck`、`actionlint`、`jq` 时使用它们，没装就跳过，CI 会全部
装上。每个 PR 都会跑同一套 `tests/lint.sh`、`tests/install.sh`、`tests/smoke.sh`，
所以没有「只在我机器上测过」这种事。

## 目录结构

~~~text
install.sh               唯一入口：创建 agent 容器的 TUI
installer/lib/           engine.sh、state.sh、ui.sh、agents.sh、commands.sh
image.env                镜像身份与构建参数
Containerfile            构建契约：context 阶段 + 镜像阶段
Justfile                 本地构建、镜像检查与发布辅助 recipe
build_files/             模块化的构建脚本（build.sh + lib/ + modules/）
config/                  声明式开关：modules.conf、agents.conf
system_files/            原样覆盖到 / 的文件（systemd、sysctl、profile.d）
runtime/                 镜像内的 agent-workspace CLI（version、manifest、doctor）
tests/                   lint.sh、smoke.sh、install.sh 以及假引擎桩
docs/                    架构、模块、agent、容器、回滚文档
~~~

完整设计说明见 [docs/architecture.md](docs/architecture.md)。

## 注意事项

- GHCR 新建 package 时**默认是 private**。本项目的 package 已经设为 public，匿名
  `podman pull` 与 `bootc switch` 都能用；如果你发布自己的 fork，请到 *Packages ->
  agent-workspace -> Package settings -> Change visibility* 改为 public。
- 默认基础镜像是 `ghcr.io/ublue-os/base-main:latest`（Fedora + bootc，无桌面）。
  桌面用户可把 `BASE_IMAGE` 换成 `ghcr.io/ublue-os/bluefin:stable` 或
  `ghcr.io/ublue-os/aurora:stable`；极简用户可用 `quay.io/fedora/fedora-bootc:44`。
- 容器之间彼此隔离，也与宿主隔离，但共用宿主内核：它们是容器，不是虚拟机。
- 容器里的 agent 通过 rootless podman 或 docker 以你的用户身份在宿主上运行；
  这既是本项目的意义，也是它的边界。
- `docker` 需要 `--privileged --cgroupns=host` 才能让镜像里的 systemd 当 PID 1；
  安装器会自动加上这些参数，但如果有得选，优先用 `podman`。

## 首次开机

任何实例（容器或裸机）首次启动时，一次性的 `agent-workspace-firstboot.service`
会创建非特权用户 `agent`（可用 `AGENT_USER` 或每机的
`/etc/agent-workspace/config.env` 调整），为它分配 sub-id 范围以便 rootless podman
可用，并开启 lingering。另有每日 `agent-workspace-health.timer` 运行
`agent-workspace doctor --quiet`，让漂移出现在 `journalctl` 里，而不是某个 agent
会话的报错里。

## 参与贡献

欢迎提 issue 与 PR，见 [CONTRIBUTING.md](CONTRIBUTING.md) 与
[SECURITY.md](SECURITY.md)。本项目遵循
[Contributor Covenant](CODE_OF_CONDUCT.md)。

## 许可证

[MIT](LICENSE) (c) 2026 Wraindrock。
