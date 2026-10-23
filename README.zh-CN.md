# TodeX Agent 容器

[English](README.md)

这是一个 Docker 镜像，内置 `todex-agentd`（[TodeX 后端](https://github.com/youtonghy/TodeX_backend)）和 Agent CLI，可以直接与 TodeX Desktop 配对。Agent 在容器里运行，只能访问你挂载进去的宿主机目录，碰不到机器上的其他东西。

镜像预装 Codex、OpenCode、Pi。它们都是开源许可，每个镜像版本固定。Claude Code 的许可不允许放进公开镜像，所以在首次启动时装进容器的 home 卷。其他 TodeX Provider（Grok Build、Devin、Antigravity、DeepSeek Harness）也可以这样安装，或者在 Desktop 的 CLI 管理页里安装。

## 快速开始（Linux、macOS）

```sh
curl -fsSLO https://raw.githubusercontent.com/youtonghy/TodeX_container/main/bin/todexc
chmod +x todexc
./todexc up --mount ~/projects
```

`todexc` 需要 Docker 和 Compose v2。容器以你的用户 ID 运行，后端发布在 `127.0.0.1:7345`，`~/projects` 在容器里也挂在同一路径。

接下来在 TodeX Desktop 里操作：

1. **配对。** 设置 → 后端连接 → 添加，填 `http://127.0.0.1:7345`，开始配对，Desktop 会显示验证码。在宿主机运行 `./todexc pair`，输入这个验证码，Desktop 随即连上。
2. **同步 Agent 配置。** 如果 Desktop 也配对了你原有的 TodeX 后端，新后端会提示“同步 Agent 配置”。同步内容包括：Provider 账号（API Key、Base URL）、CLI 设置和指令、MCP 服务器、技能。容器上已有的内容不会被删除。SSH 主机默认不同步，因为容器里没有你的私钥。
3. **开始工作。** 新建工作区，用“本地选择”选 `~/projects` 下的目录。容器内外路径相同，所以 Agent 输出的路径、git worktree、Desktop 里的“打开”都对得上。

订阅登录（Codex 用 ChatGPT 账号、Claude Code 用 Claude 账号）可能需要在容器里登录一次：在 Desktop 中打开这个后端的终端，运行 `codex login --device-auth`，或者运行 `claude` 后输入 `/login`。登录状态保存在 home 卷里。

## `todexc`

| 命令 | 作用 |
| --- | --- |
| `todexc up [--mount PATH[:TARGET]]... [--port N] [--listen ADDR] [--agents LIST] [--ssh-agent] [--tag TAG]` | 创建或更新实例并启动；选项会被记住 |
| `todexc pair [CODE]` | 批准 Desktop 的配对请求；暂时没有请求时会等待 |
| `todexc devices [revoke ID]` | 列出已配对设备，或撤销其中一个 |
| `todexc mount list\|add PATH[:TARGET]\|rm PATH` | 修改挂载目录；容器会重建，home 卷保留 |
| `todexc upgrade` | 拉取新镜像并重建容器 |
| `todexc status`、`logs [-f]`、`shell`、`down` | 查看状态、以 `todex` 身份进入 shell、停止；`down` 保留 home 卷 |

在命令前加 `--name NAME` 可以同时运行多个实例，每个实例要用不同的 `--port`。实例配置保存在 `~/.config/todex-container/<name>/`。

- `--mount PATH` 按原路径挂载。`PATH:TARGET` 挂到别的路径。每个挂载都会作为宿主路径和容器路径的映射公布出去，Desktop 的“本地选择”和“打开”靠它换算路径。
- `--agents` 指定首次启动时安装的 CLI，默认 `claude-code`，传 `""` 表示不装。
- `--ssh-agent` 把宿主机的 SSH agent 转发进容器，Agent 就能用你的密钥 `git push`。默认关闭。
- `--listen 0.0.0.0` 允许其他机器连接。对方仍然需要配对，流量全程加密。

工作区 id 由路径计算。目录被用作工作区后又换了挂载路径，它的 id 会变，所以挂载路径尽量保持不变。

## Docker Compose

```sh
cp .env.example .env   # 设置 TODEX_WORKDIR、TODEX_PATH_MAPPINGS、TODEX_UID、TODEX_GID
docker compose up -d
docker compose exec -u todex todex todex-agentd pair approve <验证码>
```

`compose.yaml` 挂载一个目录，默认按原路径挂载，设置了 `TODEX_WORKDIR_TARGET` 时挂到该路径。要挂更多目录，就在 `compose.override.yaml` 里加 `volumes`，并把所有挂载目标用 `:` 连接，写进 `TODEX_AGENTD_WORKSPACE_ROOTS`。

### Windows 宿主机

Windows 路径无法按原路径挂载，所以要挂到 `/workspace` 下，并声明路径对应关系。在 `.env` 里写：

```sh
TODEX_WORKDIR=C:\Users\me\code
TODEX_WORKDIR_TARGET=/workspace/code
TODEX_PATH_MAPPINGS='[{"hostPath":"C:\\Users\\me\\code","backendPath":"/workspace/code"}]'
```

Desktop 会用这个映射，把“本地选择”选中的目录换成容器路径；“打开”时再换回宿主路径。

## 镜像内容

| 组件 | 位置 |
| --- | --- |
| `todex-agentd`（release 二进制，SHA-256 校验） | `/usr/local/bin/todex-agentd` |
| Node.js 24 LTS | `/opt/node` |
| Codex、OpenCode、Pi（版本见 `agents/package-lock.json`） | `/opt/todex/agents` |
| git、gh、ssh、ripgrep、jq、python3、curl | 系统包（Debian trixie） |

容器在 `tini` 下以非特权用户 `todex` 运行 `todex-agentd serve`。启动时，入口脚本依次完成三件事：把 `todex` 的 UID/GID 对齐到 `TODEX_UID`/`TODEX_GID`，安装 `TODEX_EXTRA_AGENTS` 中还没装的 CLI，然后降权。

需要长期保留的数据都在 `todex` 的 home 卷里：

- 后端数据目录 `~/.todex-agent`：配对密钥、已配对设备、Provider 配置、会话；
- 各 Agent 自己的配置和登录：`~/.codex`、`~/.claude`、`~/.config/opencode`、`~/.pi` 等；
- 之后安装的 CLI：`~/.local`。

更新靠换新镜像。后端的自更新已关闭；镜像自带的 CLI 在 Desktop 里显示“随镜像更新”。

## 安全说明

- 后端只接受已配对的设备，并强制加密传输；默认只发布在宿主机回环地址上。
- Agent 对挂载目录有完整的读写权限，也能访问网络。容器隔离的是宿主机的其余部分，挂载目录本身不受保护。
- Provider 的 API Key 以仅属主可读的文件存在 home 卷里，和直接装在宿主机上一样。备份这个卷时要把它当作机密处理。
- 不会挂载 Docker socket。

## 开发

```sh
# 用已发布的后端构建本地镜像
docker compose -f compose.yaml -f compose.build.yaml up -d --build

# 用 ../TodeX_backend 中尚未发布的后端构建
TODEX_AGENTD_SOURCE=source docker compose -f compose.yaml -f compose.build.yaml up -d --build

# 对镜像运行测试
tests/smoke.sh todex_container:local
tests/pairing-e2e/run.sh todex_container:local   # 需要 ../TodeX_protocol
```

版本固定在两个地方：`Dockerfile` 的构建参数（`TODEX_AGENTD_VERSION`、`NODE_VERSION`），以及 `agents/package.json` 和它的 lockfile。

CI（`.github/workflows/image.yml`）会做 lint，在原生 runner 上分别构建 `linux/amd64` 和 `linux/arm64`，并跑两套测试。手动运行并勾选 *publish* 时，会推送 `ghcr.io/youtonghy/todex_container` 的三个标签：`:<后端版本>`、`:<后端版本>-<yyyymmdd>`、`:latest`。

镜像背后的设计，以及后端和客户端的接口，见 [docs/PLAN.md](docs/PLAN.md)；贡献规范见 [AGENTS.md](AGENTS.md)。
