# agent-workspace

**给 coding agent 用的一次性操作系统。** `install.sh` 问你几个问题，就在你的 Linux
机器上创建容器：每个容器都是一套完整、预配置好的 Fedora bootc 系统，里面装着
你选的那个 agent。

- **只有一个入口**：`./install.sh` 的交互式 TUI。不用写 manifest，不用背
  `docker run` 参数，也不需要 root。
- **一个 agent 独占一套系统**：自己的 PID 1、systemd、用户与软件包数据库
  （SELinux 策略沿用宿主机的），所以 `dnf install`、`npm install -g` 或一次误删都留在容器里。
- **快照与回滚**：给容器打快照、回滚、事故后恢复，或者分叉出第二个容器：
  [docs/rollback.md](docs/rollback.md)。
- **声明式构建**：镜像由 `image.env`、`config/modules.conf`、`config/agents.conf`
  描述；模块与 agent 都有开关，镜像会把自己的组成写进 manifest。
- **MIT 协议**：构建脚本、配置与安装器全部开源，随意 fork。

## 快速开始

~~~bash
curl -fsSL https://raw.githubusercontent.com/wraindrock/agent-workspace/main/install.sh -o install.sh
bash install.sh
~~~

安装就这一条命令。`install.sh` 是单独一个脚本：它会自己拉取所需的库，并逐个用
脚本内置的摘要校验，所以不需要 clone，也不会在本地留下一份需要同步的代码。拉取到
的文件缓存在 `~/.cache/agent-workspace/bootstrap/`。

TUI 需要终端，所以交互安装请把脚本留在本地。只想用子命令的话，直接管道接 bash
即可 —— `-s --` 负责把参数透传过去：

~~~bash
curl -fsSL https://raw.githubusercontent.com/wraindrock/agent-workspace/main/install.sh \
  | bash -s -- list
~~~

TUI 会依次问你：容器里装哪个 agent、容器叫什么名字、生命周期选 **persistent**
（systemd 常驻，home 卷跨重启保留）还是 **ephemeral**（跑完即弃）、把主机上哪个
目录挂载到 `/workspace`，以及那个 agent 需要的凭据。之后它创建好容器，并告诉你
怎么进去。凭据会写进 `~/.config/agent-workspace/containers/` 下权限 `0600` 的文件，
再以 `--env-file` 交给容器，绝不进镜像；如果你跳过这一步，容器照样会创建，但安装器
会明确告诉你：在把密钥补进去之前，它的 agent 没有可用的模型。

正式创建之前，安装器会先确认镜像就是仓库现在给的那个——像 `latest` 这种 tag，本地
副本可能是几天前的，用它建出来的容器会以看起来像引擎 bug 的方式失败。digest 和本地
自建的镜像（`localhost/...`）没有可刷新的来源，按原样使用；`--no-pull` 则完全不问
仓库，直接用本地副本。

本地没有 checkout 时，子命令也用同一条管道调用：

~~~bash
iw() { curl -fsSL https://raw.githubusercontent.com/wraindrock/agent-workspace/main/install.sh | bash -s -- "$@"; }
iw list              # 这台机器上已经有什么
iw enter dsh-box     # 在它自己的系统里运行 agent
iw --help            # 所有子命令，含非交互用法
~~~

`main` 是已审核代码的落点，`dev` 更早拿到改动，两者都能装，校验方式完全相同：

~~~bash
curl -fsSL https://raw.githubusercontent.com/wraindrock/agent-workspace/dev/install.sh \
    | AW_INSTALL_REF=dev bash -s -- --help
~~~

脚本与 `AW_INSTALL_REF` 要用同一个 ref。每个分支的 `install.sh` 只带自己分支的摘要，
所以让 `main` 的脚本去拉 `dev` 的文件会被拒绝，而不是悄悄混用两棵树——这个拒绝
就是校验在起作用，也正是它挡住了「镜像站给你换了别的代码」。

如果你更想先读代码再运行，那就改成 clone：checkout 会被直接使用，安装器本身完全
不需要网络。

~~~bash
git clone https://github.com/wraindrock/agent-workspace
cd agent-workspace
./install.sh
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

任何实例首次启动时，镜像会创建持有 agent 工作区、并且是 web UI 运行身份的 `agent`
用户（见[首次开机](#首次开机)）。这样直接跑起来的实例不会自己启动 web UI：安装器会
为它创建的容器启动，其他容器用 `./install.sh web` 启动。

## “声明式”在这里的含义

三个文件描述一切，镜像自己会证明它符合这些描述：

| 文件 | 声明内容 |
| --- | --- |
| `image.env` | 镜像身份：名称、组织、描述、默认 tag、基础镜像、agent 用户名 |
| `config/modules.conf` | 哪些构建模块参与（`20-container-tools=1`、`40-agent-harnesses=1` ……） |
| `config/agents.conf` | 安装哪些 agent（`dsh=1`、`opencode=1` ……） |

构建时，pipeline 会在**镜像内**写入 `/usr/share/agent-workspace/manifest.json`，
记录执行过的模块、安装的 agent、工具链版本以及精确的基础镜像。在已部署的主机上：

~~~bash
agent-workspace manifest | jq '.modules, .agents, .baseImage'
~~~

`agent-workspace doctor --strict` 在机器与自己的 manifest 不一致时返回非零退出码，
供测试使用；每日健康检查定时器跑的是 `agent-workspace doctor --quiet`，只记录结果。

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
| `45-dsh-plugins` | 默认 DSH 插件集，按提交进仓库的 lockfile 在构建期装好，容器无需联网即可加载 |
| `50-devtools` | neovim、ripgrep、tmux、tree、zsh、ShellCheck、direnv、fd-find、git-delta、htop、make（可选 bat、btop、eza、starship） |
| `60-system-config` | systemd 单元、registries 配置、profile.d、`/etc/skel` |
| `80-manifest` | 写出镜像 manifest 与模块清单 |
| `90-cleanup` | 清理缓存与日志，保持镜像精简 |

模块契约与新增模块的方法见 [docs/modules.md](docs/modules.md)。

## Agent

`config/agents.conf` 决定镜像里装哪些 agent，配方位于
`build_files/modules/40-agent-harnesses/agents/`。默认启用 **DSH（DeepSeek Harness）**
与 **OpenCode**；Claude Code、Codex CLI、Gemini CLI、Aider 的配方也都在，把对应的一行
改成 `1` 就会装进镜像。镜像会把自己支持的 agent 写进 manifest（`agentCatalog`），
`install.sh` 的菜单以内置 `dsh`、`opencode` 为底、再合并镜像的 `agentCatalog`，
所以既跟随构建，也在读不到 manifest 时保留内置项。详情见 [docs/agents.md](docs/agents.md)。

### 默认 DSH 插件集

镜像里带着本项目维护者自己在用的那套 DSH 插件，作为一份装好的 profile 放在
`/usr/share/agent-workspace/dsh/profiles/web`：插件清单、workspace 设置、lockfile，
以及构建期装好的 `node_modules`。插件名单以
[`system_files/usr/share/agent-workspace/dsh/profiles/web/package.json`](system_files/usr/share/agent-workspace/dsh/profiles/web/package.json)
为准，实际装进镜像的就是提交进仓库的 `pnpm-lock.yaml` 解析出的那一份。

DSH 只从 agent 自己的 `$HOME/.dsh` 读取 profile，而该目录位于容器的 workspace 卷里，
所以首次启动会把镜像里这份播种到 `/home/agent/.dsh/profiles/web`——播种发生在完成标记
之前，因此 web UI 不会在一个还没有 profile 的家目录上启动。由于每建一个新容器（同一个
卷）这一步都会再跑一遍，规则刻意收得很窄：

- 缺失就播种；已经是镜像这一版的插件集就完全不动；
- 记录的是旧版本就整体刷新：依赖清单、lockfile 与 `node_modules` 一起替换；
- `cordis.patch.yml` 属于你：只在首次播种时写一次，之后永不覆盖，偏好写这里而不是
  `package.json`；
- 你改过的 profile 会被原样保留，并给出警告指明目录与它偏离的那一版插件集。想改用镜像
  这一版，就在容器里删掉 `/home/agent/.dsh/profiles/web`，让下一次首次启动重新播种
  （`./install.sh upgrade dsh-box`，或 `recover`、`fork`、重建）。

完全不要这套插件集的构建把模块关掉即可：`config/modules.conf` 里写 `45-dsh-plugins=0`，
或在 `--build-arg IMAGE_MODULES=...` 里不带它。

这些插件都是第三方 npm 包：它们的 lifecycle 脚本在镜像构建期以 root 运行，之后其代码在
agent 容器里运行。见 [SECURITY.md](SECURITY.md)。想确认某个运行中的容器到底装了什么：

~~~bash
./install.sh enter dsh-box ls /home/agent/.dsh/profiles/web
./install.sh enter dsh-box cat /home/agent/.dsh/profiles/web/.agent-workspace-profile
~~~

后一个文件记录该 profile 是从哪一版插件集播种来的，以及镜像拥有的每个文件的摘要。

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
只跑一条命令，退出即删除。agent 菜单以内置 `dsh`/`opencode` 为底、合并镜像的
`agentCatalog`，既跟随构建，也在读不到 manifest 时保留内置项。完整说明见
[docs/containers.md](docs/containers.md)。

## 实例内的 root

默认情况下 `agent` 用户在实例里没有 `sudo` 权限。它能不能在实例内变成 root，是一个由你
随时拨动的开关，而不是创建容器时就定死的东西：

~~~bash
./install.sh root dsh-box status   # 默认。以实测为准，不是看文件
./install.sh root dsh-box on       # 写 /etc/sudoers.d/agent-workspace，NOPASSWD，权限 0440
./install.sh root dsh-box off      # 删掉规则、轮换密码并锁定账号
~~~

`on` 立即生效：`sudo` 每次调用都会重读 `sudoers.d`，所以 agent 下一次 `sudo` 就能用，
不用重启、也不用重新登录。规则只授予 `agent` 用户；它先写到临时文件、用 `visudo -cf`
校验通过后才会生效——坏掉的 sudoers 文件绝不会被装上。两个方向都是幂等的：重复你已经
是的那个词，只会重新实测并说明“已经是了”，不改动任何东西。`status` 以 agent 身份执行
`sudo -n true`，并单独报告规则文件是否存在，所以“文件在”和“sudo 真的放行了”不会被混为
一谈。实例已停止时它无法回答，会直接说明，而不是猜一个结果。

`on` 还会给 agent 账号设一个新随机密码，并存到宿主机上的
`~/.config/agent-workspace/credentials/<name>.root`（权限 `600`），和容器凭据放在一起
——这是宿主机为这个开关唯一保留的东西，也是你在实例里以 agent 身份登录时要用的那个值。
它永远不会被打印，只打印路径。`off` 会删掉规则，把该密码轮换成一个谁都不保存的值，
锁定账号、删除宿主侧文件，然后实测 `sudo -n true` 确实失败。

`off` **不会**收回已经在运行的东西：agent 此前以 root 启动的进程会一直保留这个权限，直到
它退出。另外，实例内的 root 与 agent 本身属于同一个信任域——它是容器里的 root，永远不是
宿主机的 root；这条边界在 [SECURITY.md](SECURITY.md) 里写得很清楚。

## 在宿主机打开 agent 的 web UI

DeepSeek Harness 自带 web UI。容器只把它绑在自己的回环上，安装器把它发布到你的回环
——并且会替你启动它：容器的首次启动一创建出 web UI 所运行的 `agent` 用户，就把它拉
起来；凡是将容器留在运行状态的命令都会这么做：`create`、`start`、`restart`、
`recover`、`rollback`、`fork`、`upgrade`。UI 起来后会打印一个一次性链接：

~~~
✓ dsh web UI is published on http://127.0.0.1:34700/ (container port 3080)
  open: http://127.0.0.1:34700/?token=...
~~~

第一次访问会在浏览器里写入 30 天有效的 cookie，因此 token 只需要用一次。如果 UI 没在
运行——容器在安装器之外被停过，或创建时首次启动还没跑完——这条命令会打印同样的链接，
并且在起不来时明确报错，而不是给你一个只会把连接重置掉的网址：

~~~bash
./install.sh web dsh-box
~~~

宿主端口在创建容器时选定并跟容器一起记录，所以 `rollback`、`recover`、`upgrade` 都
沿用同一个地址，`fork` 出的新容器会另行分配。`./install.sh create --web-port 8080`
可以自己指定端口，`--no-web` 则完全不发布端口。安装器没有能力打开 web UI 的智能体
（`opencode`）根本不发布端口：发布一个后面什么都没有的端口，只会看起来像装坏了。映射
始终是 `127.0.0.1:<宿主端口>:3080`，从网络上访问不到。细节见
[docs/containers.md](docs/containers.md)。

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

镜像使用 [cosign](https://docs.sigstore.dev/) 签名。发布默认通过 GitHub 的 OIDC
身份做 keyless 签名：

~~~bash
cosign verify \
  --certificate-identity-regexp '^https://github.com/wraindrock/agent-workspace/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/wraindrock/agent-workspace:latest
~~~

如果你更信任固定公钥，运行 `just cosign-keygen` 并把私钥存为仓库 secret
`SIGNING_SECRET`，工作流会自动切换到密钥签名。

## 自己构建镜像

~~~bash
git clone https://github.com/wraindrock/agent-workspace
cd agent-workspace
just check     # 仓库自检，不需要 podman
just build     # 用 podman 构建镜像
just verify    # 构建 + 全部容器级测试
just verify-all # 上述内容再加无需引擎的契约测试
~~~

依赖：任选一个后端——`podman`、`docker` 或 `incus`（见[后端](#后端)）；`kvm` 是推荐但尚未实现——
`install.sh` 另需 bash 4.4+；构建与自检还需要 `just`。
仓库自检在装了 `shellcheck`、`actionlint`、`python3`+`pyyaml` 时使用它们，
没装就跳过；`tests/smoke.sh` 另需 `jq`。CI 只显式安装 `actionlint` 与 `just`，其余
依赖运行器镜像自带的 `shellcheck`、`jq`、`python3`。每个 PR 都会跑同一套十一个测试
脚本：`tests/lint.sh`、`tests/install.sh`、`tests/smoke.sh`、`tests/integration.sh`、
`tests/portability.sh`、`tests/decoupling.sh`、`tests/contract.sh`、
`tests/firstboot.sh`、`tests/bootstrap.sh`、`tests/i18n.sh`、`tests/incus.sh`。
其中 `integration` 会通过 `install.sh` 创建真实容器，
`portability` 证明镜像在从未调优过内核参数的宿主上也能启动，两者都需要宿主能用
rootless podman 启动 systemd；其余都是静态或 CLI 级测试（`incus` 用假守护进程），
不需要引擎、root 与网络。所以没有「只在我机器上测过」这种事。

## 目录结构

~~~text
install.sh               唯一入口：创建 agent 容器的 TUI
installer/lib/           engine.sh（后端加载器）、backend-*.sh、state.sh、ui.sh、agents.sh、commands.sh
image.env                镜像身份与构建参数
Containerfile            构建契约：context 阶段 + 镜像阶段
Justfile                 本地构建、镜像检查与发布辅助 recipe
build_files/             模块化的构建脚本（build.sh + lib/ + modules/）
config/                  声明式开关：modules.conf、agents.conf
system_files/            原样覆盖到 / 的文件（systemd、profile.d、registries）
runtime/                 镜像内的 agent-workspace CLI（version、manifest、modules、agents、status、doctor）
tests/                   lint、install、smoke、integration、portability、
                         decoupling、contract、firstboot、bootstrap、i18n、incus 以及假引擎桩
docs/                    架构、模块、agent、容器、回滚文档
~~~

完整设计说明见 [docs/architecture.md](docs/architecture.md)。

## 界面语言

`install.sh` 说宿主机 locale 所指定的语言，按 `LC_ALL` → `LC_MESSAGES` → `LANG` 的顺序解析。
目前有英文和简体中文（`zh`）两套译文；其他 locale 整体回退到英文，而不是显示半中半英。
想显式指定，设 `AW_LANG_OVERRIDE=en`（或 `zh`）。

翻译覆盖的是安装器对你说的一切：TUI、提问、章节标题、表头、`--help`、`doctor`，以及每一条
报错和确认。`tests/i18n.sh` 会断言没有任何消息绕过目录、没有 key 被重复定义、且 `--help`
的命令与选项列在两种语言下逐字节一致——这样译文就不可能悄悄改掉一个选项名。

有四类内容故意保持英文，这是边界而不是疏漏：「需要 bash 4.4」的守卫和 bootstrap 的
「fetched N files」，它们在目录被拉取之前就要打印；`CONTAINER=`/`NAME` 声明文件格式，
它是机器可读的；以及 `dry-run` 标签和它打印的引擎命令，那是一条你可以直接复制的 shell 命令。

## 后端

`install.sh` 不直接跟任何一种引擎打交道：它只调用一组固定动词（create、exec、
logs、copy、remove……），由后端实现。**没有 `auto`**：探测宿主后自己挑一个，会把
只有你能权衡的取舍藏起来，所以 `install.sh` 绝不替你决定。

- `--backend NAME`（`--engine` 是等价别名）为这一次运行指定后端，且不会写回你记住的选择；
- 不传 `--backend` 时用记住的选择；没有记住的选择、又有终端时，打印下面的清单让你选，
  选完会记住；
- 没有终端、也没有记住的选择时，打印同一张清单并**非零退出**，不猜。

`./install.sh backend` 查看记住的选择，`./install.sh backend set NAME` 修改它（存在
`${XDG_CONFIG_HOME:-~/.config}/agent-workspace/backend`，权限 600）。后端同时记在容器
状态里，已有容器沿用创建时的后端；`install.sh doctor` 两处都会显示。

| 后端 | 工作区是什么 | 取舍 |
| --- | --- | --- |
| `kvm` **推荐** | 一套完整系统：自己的内核、init 与模块 | 需要内核的操作都能做；代价是首次要把镜像做成可启动磁盘，并真实占用内存与磁盘 |
| `podman` **推荐** | 你自己 rootless podman 里的一个容器 | 最轻最快、无需准备；共享宿主内核，有些操作结构上做不到 |
| `docker` 备选 | 你 docker 里的一个容器 | 共享宿主内核的代价相同；实例里的 init 需要 `--privileged --cgroupns=host`（安装器会加）；已经用 docker 的环境方便 |
| `incus` *本版本暂不可选* | 一个非特权 Incus 实例 | 可见且实现仍在；本版本在这套宿主系统上会拒绝选择它 |

清单会按宿主实际情况标注：没装的后端标 `not installed`，`incus` 标
`not selectable in this version`。

### Incus 可见，但不隐藏也不可选

`installer/lib/backend-incus.sh` 保留在仓库里、保留在清单里、也仍被测试覆盖；被闸门挡住的
只是**选择**。`--backend incus` 与 `./install.sh backend set incus` 会明确失败，说明本版本
在这套宿主系统上暂不可选，以及以后如何恢复（换一套宿主系统；闸门是
`installer/lib/engine.sh` 里的一个变量）。

只有 Incus 后端需要你先在宿主上做一次性准备，而且这一步 `install.sh` 不会替你做
（装不装 incus、启不启守护进程、存储池与网桥怎么建，都该由宿主决定）：

~~~bash
sudo systemctl enable --now incus.socket   # 或：sudo systemctl enable --now incus
sudo incus admin init --minimal            # 建默认存储池与 incusbr0 网桥
~~~

`install.sh` 永远不跑 `sudo`、不写 `/etc`、也不启动任何守护进程。

Incus 工作区有三点值得知道：

- agent 的 home 是**宿主上的一个目录**
  （`~/.local/share/agent-workspace/incus/homes/<name>`），不是命名卷，用
  `shift=true` 挂进实例后属主就是 agent 用户；`backup`、`fork`、`rollback` 都是拷文件，
  没有 `podman commit`；
- web UI 由绑在 `127.0.0.1` 的 `proxy` 设备发布，因此端口依然只在回环上；
- 它是**非特权实例**：容器里的 root 只是你用户的一个 subuid/subgid 映射，和别的后端
  一样共用宿主内核，**不是虚拟机**。

OCI 镜像不是以镜像引用交给守护进程的：后端先用 `podman`（或 `docker`）导出，
经 `xz` 管道给 `incus image import`，并按镜像 ID 缓存起来，所以浮动 tag 只有在
digest 真的变了才会重新导入。每个后端的细节与尚未验证的部分见
[docs/containers.md](docs/containers.md#backends)。

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
- `incus` 后端可见但本版本暂不可选，需要先做[后端](#后端)里那条一次性宿主准备。

## 首次开机

任何实例（容器或裸机）首次启动时，一次性的 `agent-workspace-firstboot.service`
会创建 `agent` 用户（可用 `AGENT_WORKSPACE_USER` 调整，写在每机的
`/etc/agent-workspace/config.env` 里），把它加入 `wheel` 组，为它分配 sub-id 范围
以便 rootless podman 可用，并开启 lingering。该用户持有 agent 工作区、也是 web UI
的运行身份；终端侧（`install.sh enter`、`install.sh shell`）以容器自身的 root 用户
执行 agent CLI，所以容器对 agent 并不是安全边界。另有每日
`agent-workspace-health.timer` 运行 `agent-workspace doctor --quiet`，让漂移出现在
`journalctl` 里，而不是某个 agent 会话的报错里。

同一个服务会把镜像自带的默认 DSH 插件集播种进 agent 的家目录（见
[默认 DSH 插件集](#默认-dsh-插件集)），并且把完成标记写在最后：之前任何一步失败都只报告、
不阻断，避免半装好的容器被当成装好的容器。

## 参与贡献

欢迎提 issue 与 PR，见 [CONTRIBUTING.md](CONTRIBUTING.md) 与
[SECURITY.md](SECURITY.md)。本项目遵循
[Contributor Covenant](CODE_OF_CONDUCT.md)。

## 许可证

[MIT](LICENSE) (c) 2026 Wraindrock。

agent-workspace 构建在 Fedora bootc 与
[Universal Blue](https://universal-blue.org/) 社区的工作之上；本项目是独立项目，
与两者均无隶属关系。
