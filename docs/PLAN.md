# TodeX Agent 容器：方案与接口计划

状态：已批准（2026-10-23），第 6 节决策采用计划建议。依据 `TodeX_backend`（`dad2ed7`）、`TodeX_desktop`（`e4c4146`）、`TodeX_protocol`（`72a7eb2`）、`TodeX_web` 当前 `main` 的只读调查。

## 1. 目标与完成标准

用户在一台装有 Docker 的机器上用一条命令启动容器。容器里有 `todex-agentd` 和主流 Agent CLI。用户在 TodeX Desktop 里添加并配对这个后端，从已有的 TodeX 后端把 Agent 配置同步过来，选择本机目录建工作区，Agent 在容器里改的就是本机挂载进来的文件。

完成标准（都可检查）：

1. `todexc up --mount ~/git` 或 `docker compose up -d` 后，容器在 30 秒内变为 healthy；宿主机 `curl http://127.0.0.1:7345/health` 返回 `ok`。
2. 未签名的 `GET /v2/version` 返回 `deployment: "container"`；容器内 `todex-agentd doctor providers --format json` 显示预装的 CLI 均已安装。
3. Desktop 添加 `http://127.0.0.1:7345` 并发起配对后，宿主机执行一条命令（`todexc pair`）即可批准，Desktop 自动连上。
4. 配对后 Desktop 提示从已有后端同步配置；同步 accounts / settings / mcp / skills 无错误完成（`absolutePath` 提示除外）。
5. 在 Desktop 新建工作区时用“本地选择”选中已挂载的目录，后端接受该路径；Agent 在其中创建的文件在宿主机上归宿主用户所有。
6. `docker compose down && up`、`todexc upgrade` 之后，配对、Provider 配置、Agent 登录状态、会话历史都还在。
7. `linux/amd64` 和 `linux/arm64` 镜像发布到 `ghcr.io/youtonghy/todex_container`。

必须保持不变的行为：

- 后端在宿主机上的默认行为不变。新增的环境变量全部默认关闭，新增的响应字段都是可选追加。
- 配对协议 v3 和 transport v2 规则不变；不新增任何网络侧的配对批准入口。本机 IPC 的 local-admin API（见 3.7）不算网络侧入口：它只挂在 Unix socket 上，从不路由到 TCP，并且只接受与守护进程 euid 相同的对端 UID，等同于对数据目录的本机文件权限（同一 UID 本来就能写 `device-pairing/` 批准文件）。
- Desktop/Web 连接非容器后端时的行为不变；老后端不返回新字段时，客户端按现状处理。

## 2. 产品行为与默认决策

### 2.1 启动

`todexc up [--name todex] [--port 7345] [--mount PATH]... [--listen 127.0.0.1] [--ssh-agent] [--agents grok-build,devin,...]`

**计划采用的默认：** 本地目录按原路径挂载（宿主机 `/home/jh/git` 在容器里也是 `/home/jh/git`），挂载的目录就是后端的 `workspace_roots`。理由：Agent 输出、git worktree 的 `.git` 文件、Desktop 的“本地选择”都用绝对路径，原路径挂载时这些路径在宿主机和容器里都成立，不需要转换。Windows 宿主机做不到原路径挂载，改用 `/workspace/<名字>` 加路径映射（见 2.4）。

**计划采用的默认：** 端口只发布在宿主机回环（`127.0.0.1:7345`）。局域网访问需显式 `--listen 0.0.0.0`，此时仍要求配对和加密传输（后端现有规则）。

**计划采用的默认：** 容器内 `todex` 用户的 UID/GID 与宿主机当前用户一致（`todexc` 自动传 `id -u`/`id -g`），这样挂载目录的读写权限和文件归属都正确。宿主用户是 root 时拒绝启动并提示。

**计划采用的默认：** 状态都放在命名卷 `todex-<name>-home`（挂到 `/home/todex`）：后端数据目录 `~/.todex-agent`，以及 `~/.codex`、`~/.claude`、`~/.claude.json`、`~/.config/opencode`、`~/.pi`、`~/.local`、`~/.gitconfig`、`~/.ssh`。

`--ssh-agent` 把宿主机的 SSH agent socket 转发进容器（后端已把 `SSH_AUTH_SOCK` 传给 Agent 子进程），用于 git push。**计划采用的默认：** 关闭，需要时显式开启。

### 2.2 配对

1. Desktop：设置 → 后端连接 → 添加，URL 填 `http://127.0.0.1:7345`，点配对。
2. Desktop 读到 `deployment: "container"` 后，在验证码旁边显示批准方法：`todexc pair`，或 `docker exec -u todex <容器名> todex-agentd pair approve <验证码>`（验证码已填好，可复制）。
3. 宿主机运行 `todexc pair`：列出待批准请求（设备名、验证码、传输指纹、来源地址、剩余时间），确认后批准。
4. Desktop 轮询到批准结果，自动连接。

请求 5 分钟过期（后端现有规则）；过期后 Desktop 提示重新配对。撤销设备用 `todexc devices revoke <deviceId>`。

### 2.3 同步 Agent 配置

Desktop 本身不存 Agent 配置，配置都在各个后端上。Desktop 已有“配置同步”：从一个源后端单向、增量地同步到目标后端，不删除目标端已有内容，按可移植的键匹配。类别是 accounts（Provider 账号，含密钥，走加密传输）、settings、mcp、skills、ssh。

新增行为：配对完成后，如果新后端还没有任何 Provider 账号，并且 Desktop 还连着另一个已配对后端，后端详情页出现“从「<源后端>」同步 Agent 配置”卡片。点击后打开现有的配置同步界面，目标已选为这个容器。

**计划采用的默认：** 源后端选最近连接过的另一个后端；预选 accounts、settings、mcp、skills，不选 ssh（容器里没有对应私钥，后端会把这些主机标为 blocked）。

ChatGPT / Claude 订阅这类 OAuth 登录是否包含在 accounts 同步里，实施时验证。不包含的话，在 Desktop 的终端里对容器执行 `codex login --device-auth` 或 `claude` 的 `/login`，登录状态保存在 home 卷里。

### 2.4 工作目录

- 原路径挂载时：Desktop 新建工作区的“本地选择”直接可用。选了没挂载的目录时，后端返回 `WORKSPACE_PATH_OUTSIDE_ROOT`，Desktop 在容器后端上把它显示成“该目录没有挂载进容器”，并给出 `todexc mount add <路径>`。
- `todexc mount add|rm|list`：改挂载需要重建容器。命名卷不受影响，配对和会话都保留；正在运行的 Agent 回合会中断，命令执行前会提示。
- Windows 或自定义布局：挂载到 `/workspace/<名字>`，后端通过 `TODEX_AGENTD_PATH_MAPPINGS` 公布宿主机路径和容器路径的对应关系。Desktop 用它把“本地选择”的路径换成容器路径，把“打开 / 在文件夹中显示”的容器路径换回宿主机路径。
- **计划采用的默认：** 后端是容器、又找不到映射时，Desktop 隐藏“打开 / 打开方式 / 在文件夹中显示”。现在只要 URL 是回环地址就会显示这些菜单，并且会拿容器内路径去打开本机文件，这个现有缺陷顺带修掉。

### 2.5 Agent CLI

- 预装的 CLI 装在 `/opt/todex/agents`，版本随镜像固定。Desktop 的 CLI 管理页对它们显示“随镜像更新”，不提供升级按钮；更新方式是 `todexc upgrade`（拉新镜像并重建容器）。
- 其他 CLI 在 Desktop 里照常安装，或通过 `--agents` / `TODEX_EXTRA_AGENTS` 在启动时安装，装进 home 卷的 `~/.local`，重建后仍然在。`PATH` 让 `~/.local/bin` 排在 `/opt/todex/agents/bin` 前面。
- 预装哪些 CLI：见第 6 节决策。
- Gemini：后端没有 Gemini CLI 适配器，Google 系走 Antigravity（`agy`，配置在 `~/.gemini`），它属于启动时可选安装的那一类。

### 2.6 其他行为

- 预览：Agent 在容器里起的开发服务器，Desktop 通过现有的预览代理（`POST /v2/browser/proxy`）访问，不需要额外发布端口。
- Computer Use 在容器里不可用（没有显示服务），后端已经能优雅降级。Agent 浏览器不在默认镜像里。
- 后端自更新关闭；容器里执行 `todex-agentd update` 时提示“由镜像管理”。

## 3. 推荐技术方案

### 3.1 架构

```
宿主机                                         容器 todex（Debian，非 root 用户 todex）
┌──────────────────┐   127.0.0.1:7345        ┌────────────────────────────────────────────┐
│ TodeX Desktop    │ ──── 配对 v3 / v2 ────▶ │ tini → todex-entrypoint → todex-agentd serve│
│  - 配对          │      sealed + ws        │   0.0.0.0:7345，需认证 + ml-kem-768        │
│  - 配置同步      │                         │   ├─ codex / claude / opencode / pi …      │
│  - 工作区/会话   │                         │   └─ git / ssh / node / gh / rg            │
└────────┬─────────┘                         │ /home/todex       ← 命名卷（状态、登录）    │
         │ 源后端（已有 TodeX 后端）          │ /home/jh/git      ← bind mount（原路径）    │
         ▼                                   └────────────────────────────────────────────┘
   todex-agentd（宿主机或远端）          todexc pair → docker exec -u todex … pair approve
```

### 3.2 现有能力与缺口

| 需求 | 已有能力 | 缺口 → 本计划新增 |
| --- | --- | --- |
| 无头运行 | `serve` 前台运行，处理 SIGTERM，日志到 stdout；没有显示服务时 Computer Use 自动降级 | 无 |
| 监听 0.0.0.0 | 允许，前提是开启认证且加密不为 `none`（默认满足） | 日志里打印的是容器 IP → `ADVERTISE_URL` |
| 配对批准 | 只能在后端 TUI 里批准（写 `device-pairing/decision-<id>.json`，要求属主等于守护进程 euid、权限 0600） | 无头批准 → `pair list/approve/reject` CLI |
| 设备管理 | 只有 TUI | `devices list/revoke` CLI |
| 配置同步 | Desktop `configSync` 已覆盖 accounts/settings/mcp/skills/ssh | 配对后的入口卡片；容器场景的默认类别 |
| CLI 安装 | `POST /v2/providers/{p}/install` 走厂商安装脚本 / npm | 启动时声明式安装 → `providers install` CLI |
| CLI 升级 | `<cli> update`，写用户目录 | 镜像预装的 CLI 不可升级 → `managedBy: "image"` |
| 自更新 | `TODEX_AUTO_UPDATE=0` 可关闭；`daemon-run` 更新时会退出，导致容器 PID 1 退出 | 容器里关闭；`update` 明确拒绝 |
| 工作目录 | `workspace_roots` 限制，路径都是后端侧绝对路径 | 原路径挂载；非原路径时用 `PATH_MAPPINGS` |
| 是否容器 | 无 | `/v2/version` 增加 `deployment` |
| 发布产物 | Linux 只有 glibc 2.28 的 gnu 构建（x64 / arm64），附 `SHA256SUMS` | 镜像只能用 Debian 系，不能用 Alpine |

### 3.3 镜像设计

- 基础镜像：`debian:trixie-slim`，多阶段构建。
  - `fetch` 阶段（`--platform=$BUILDPLATFORM`）：按 `TARGETARCH` 下载 `todex-agentd-v<ver>-linux-{x64,arm64}-gnu.bin` 并用 `SHA256SUMS` 校验，`SHA256SUMS` 本身须经 `SHA256SUMS.sig`（后端发布密钥对「`todex-release-v1\0` + 标签 + `\0` + `SHA256SUMS`」的 Ed25519 签名，公钥副本在 `keys/todex-release-signing.pub.pem`）以 `openssl pkeyutl -verify -rawin` 验证，v2.3.6 及更早的版本发布于签名之前，只校验哈希并在构建日志中警告；下载 Node.js 24 LTS 并校验 `SHASUMS256.txt`。
  - `runtime` 阶段：安装 `ca-certificates curl git openssh-client bash procps tini ripgrep jq less python3 gh xz-utils unzip`，复制 Node 和 `todex-agentd`，把预装 CLI 装到 `/opt/todex/agents`（root 属主），创建 `todex` 用户（默认 UID/GID 1000）。
- CLI 版本由 build arg 固定（`CODEX_VERSION`、`OPENCODE_VERSION`、`PI_VERSION`……）：有 npm 包的 CLI 用 `npm install --prefix /opt/todex/agents <pkg>@<ver>`，没有的用厂商安装脚本（`HOME` 指向临时目录，装完移到 `/opt`）。解析出的版本写进 OCI label。
- 入口：`ENTRYPOINT ["/usr/bin/tini","--","/usr/local/bin/todex-entrypoint"]`，`CMD ["todex-agentd","serve"]`。`todex-entrypoint` 以 root 运行，依次：
  1. 校验 `TODEX_UID`/`TODEX_GID`（拒绝 0），必要时 `usermod`/`groupmod`；
  2. 只修正 home 卷顶层及已知子目录的属主，不递归进挂载的工作目录；
  3. 如果设置了 `TODEX_GIT_NAME`/`TODEX_GIT_EMAIL` 且 `~/.gitconfig` 里还没有，就写入；
  4. 以 `todex` 身份执行 `todex-agentd providers install --if-missing $TODEX_EXTRA_AGENTS`，失败只记日志，不阻止启动；
  5. `exec setpriv --reuid todex --regid todex --init-groups -- "$@"`。
- 容器内固定的环境变量：`TODEX_AGENTD_HOST=0.0.0.0`、`TODEX_AGENTD_PORT=7345`、`TODEX_AGENTD_DATA_DIR=/home/todex/.todex-agent`、`TODEX_AGENTD_DEPLOYMENT=container`、`TODEX_AGENTD_IMAGE_CLI_DIR=/opt/todex/agents/bin`、`TODEX_AUTO_UPDATE=0`，`PATH` 以 `/home/todex/.local/bin` 开头。`TODEX_AGENTD_WORKSPACE_ROOTS` 由 `todexc`/compose 传入，未设置时为 `/workspace`。
- `EXPOSE 7345`；`HEALTHCHECK CMD curl -fsS http://127.0.0.1:7345/health`；`STOPSIGNAL SIGTERM`。
- 镜像标签：`<后端版本>`（可变，重建时用最新的固定 CLI 版本）、`<后端版本>-<yyyymmdd>`（不可变）、`latest`。
- `todexc`（bash，支持 Linux/macOS）：每个实例在 `${XDG_CONFIG_HOME:-~/.config}/todex-container/<name>/` 下生成一个 compose 项目（基础服务、挂载列表、端口、UID），再调用 `docker compose`。挂载点不能是保留路径（`/`、`/bin`、`/etc`、`/usr`、`/opt/todex`、`/home/todex`、`/proc`、`/sys`、`/dev`、`/run`、`/tmp`、`/var`）。子命令：`up down status logs shell pair devices mount upgrade`。

### 3.4 新增接口

#### 后端（TodeX_backend）

所有新增都是追加，宿主机默认行为不变。

**CLI**

| 命令 | 行为 |
| --- | --- |
| `todex-agentd pair list [--data-dir D] [--format text\|json]` | 列出已 reveal、未决定、未过期的请求：`requestId`、`verificationCode`、`deviceName`、`deviceId`、`peerAddress`、`transportFingerprint`、`expiresAt`。数据来自 `device-pairing/request-*.json`。 |
| `todex-agentd pair approve <验证码\|requestId> [--yes]` | 写入 `decision-<id>.json`（`approved: true`），复用 TUI 的写入函数（属主检查、0600、硬链接、不覆盖）。验证码不区分大小写，连字符可省略。参数是验证码时，验证码本身就是确认；参数是 `requestId` 时需要交互确认或 `--yes`。退出码：0 成功；2 未找到、已过期或匹配不唯一；3 当前用户不是数据目录属主（提示用 `-u todex`）。 |
| `todex-agentd pair reject <验证码\|requestId>` | 同上，写入 `approved: false`。 |
| `todex-agentd devices list [--format json]` / `devices revoke <deviceId>` | 与 TUI 的设备面板相同，复用 `devices.rs`。`devices.json` 按 mtime 重新加载，撤销无需重启。 |
| `todex-agentd providers install <id>... [--if-missing]` | 与 `POST /v2/providers/{p}/install` 走同一个 `cli_manager` 安装流程；镜像管理的 CLI 跳过。 |

这些命令都不开放网络入口，信任模型和 TUI 一样，靠本机控制目录的文件权限。

**配置（环境变量 / `config.toml`）**

| 环境变量 | `config.toml` | 含义 |
| --- | --- | --- |
| `TODEX_AGENTD_ADVERTISE_URL` | `server.advertise_url` | 启动日志、TUI 二维码、配对链接里显示的地址。只接受不带凭据、查询和片段的 http(s) URL。 |
| `TODEX_AGENTD_DEPLOYMENT` | `server.deployment` | `host`（默认）或 `container`。 |
| `TODEX_AGENTD_IMAGE_CLI_DIR` | `agent.image_cli_dirs` | 解析到这些目录下的 CLI 算作镜像管理。 |
| `TODEX_AGENTD_PATH_MAPPINGS` | `[[workspace.path_mappings]]` | JSON 数组 `[{"hostPath":"C:\\Users\\me\\code","backendPath":"/workspace/code"}]`。`backendPath` 必须是绝对路径且位于某个工作区根目录内；不能重复；配置无效时启动失败（与其他配置错误一致）。 |

**HTTP（追加字段，`docs/API.md` 同步更新）**

- `GET /v2/version`
  - 新增顶层字段 `deployment: "host" | "container"`，未签名请求也返回。Desktop 在配对前就要用它来显示批准方法；它只透露部署类型，不含镜像细节。
  - 签名可信时，路径信息里新增 `pathMappings: [{hostPath, backendPath}]`，为空时省略。
- `GET /v2/providers/versions`：`CliVersionInfo` 新增 `managedBy?: "image"`。镜像管理的 CLI 返回 `upgradeSupported: false`、`installSupported: false`。
- `POST /v2/providers/{p}/upgrade` 和 `/install`：目标是镜像管理的 CLI 时返回 409 `CLI_MANAGED_BY_IMAGE`。
- `todex-agentd update`：`deployment=container` 时不做任何改动，提示“由镜像管理”；`update --check` 照常可用。

文档：`docs/API.md`（version、providers/versions、错误码），`docs/BUILD_RUN.md`（容器一节、新环境变量、新 CLI），`docs/device-verification.md`（命令行批准）。

#### 协议层（TodeX_protocol）

- 类型：版本响应增加 `deployment?`、`pathMappings?`；`CliVersionInfo` 增加 `managedBy?`。
- 纯函数 `mapHostPathToBackend(path, mappings, { windows })` 和 `mapBackendPathToHost(path, mappings, { windows })`：最长前缀匹配，只在路径段边界匹配；Windows 下统一 `\`/`/`、不区分大小写；匹配不到返回 `null`。附单元测试。
- 字段缺失时按 `deployment: "host"`、无映射处理，兼容老后端。

#### Desktop（TodeX_desktop）与 Web（TodeX_web）

| 编号 | 改动 | Desktop | Web |
| --- | --- | --- | --- |
| D1 | `DevicePairingPanel`：后端是容器时显示批准方法和可复制命令（验证码已填入） | ✓ | ✓ |
| D2 | `BackendConnectionSettings`：配对后显示同步配置卡片，打开 `ConfigSyncSettings` 并预置目标、源和类别 | ✓ | ✓ |
| D3 | `CliManagerPanel`：`managedBy: "image"` 时显示“随镜像更新”，隐藏升级按钮 | ✓ | ✓ |
| D4 | `CreateWorkspaceModal` 的“本地选择”做宿主→容器路径映射；`WORKSPACE_PATH_OUTSIDE_ROOT` 在容器上显示挂载提示 | ✓ | 只显示提示（Web 没有本地选择） |
| D5 | Workbench 的“打开 / 在文件夹中显示”做容器→宿主路径映射；容器且无映射时隐藏 | ✓ | 不适用 |

新增文案按两个客户端现有的 i18n 方式补齐。

#### 本仓库（TodeX_container）

`Dockerfile`、`rootfs/usr/local/bin/todex-entrypoint`、`bin/todexc`、`compose.yaml`、`compose.build.yaml`（叠加层：从兄弟仓库源码构建后端，供开发用）、`.env.example`、`README.md` / `README.zh-CN.md`、`tests/smoke.sh`、`tests/pairing-e2e/`、`.github/workflows/image.yml`。

### 3.5 关键取舍

- **原路径挂载 + 可选映射，而不是统一挂到 `/workspace`。** git worktree 的 `.git` 文件、Agent 输出、Desktop 的“本地选择”都依赖绝对路径。统一挂到 `/workspace` 就必须在所有这些地方转换路径，而且 worktree 里的绝对路径根本没法转换。映射只用来兜底 Windows。
- **`pair approve` CLI，而不是一次性配对令牌自动批准。** CLI 不新增网络入口，沿用 TUI 已有的本机控制目录信任模型，改动最小。操作量上，一个是在终端敲验证码，一个是往 Desktop 粘贴链接，差别不大。令牌方案留作后续（见 5.2）。
- **用 `serve` 做主进程，而不是 `daemon-run`。** `serve` 日志走 stdout（`docker logs` 能看到）、处理 SIGTERM、不触发自更新重启；`daemon-run` 写文件日志，而且更新时会自行退出。TUI 的配对二维码需要 `daemon-run` 写的 `daemon.json`，容器场景改用 `pair` CLI，不需要二维码。
- **预装 CLI 放 `/opt` 并标记为镜像管理，而不是首次启动时安装。** 好处是启动快、离线可用、版本可复现。代价是要在后端加 `managedBy`，见第 6 节决策。
- **配置同步复用 Desktop 现有引擎。** 不在后端新增“整包导出/导入”，避免出现第二套同步语义。

### 3.6 部署顺序与回滚

1. 后端发布带新 CLI 和新字段的版本 vN（都是追加，宿主机用户无感）。
2. 协议层、Desktop、Web 发布（字段缺失时回退到现状）。
3. 容器镜像固定使用后端 ≥ vN。

第 1 步完成前，镜像可以先基于当前后端版本出 MVP，配对用 TUI 批准（步骤 1）。

回滚：镜像回退到上一个不可变标签；后端字段是追加的，老客户端会忽略；新客户端遇到老后端时按 `host` 处理。

### 3.7 本机 IPC（Linux 宿主机）

目标：同一台 Linux 机器上的 TodeX Desktop 不用敲验证码，经本地 Unix socket 连接容器并自动批准自己的配对请求。接口约定见后端的 IPC 监听和 local-admin API（`docs/API.md`）。

- **镜像：** `ENV TODEX_AGENTD_IPC_PATH=/run/todex-ipc/agentd.sock`；`/run/todex-ipc` 属于 `todex`，权限 0700。entrypoint 只修正这个挂载点本身的属主（`TODEX_UID:TODEX_GID`）和权限，不递归；启动前删除上次遗留的 socket 文件。失败只记警告，后端照常以纯 TCP 运行（目录不可写时后端也只警告）。
- **`todexc`：** 仅在 Linux 上创建 `${XDG_CONFIG_HOME:-~/.config}/todex-container/<name>/ipc/`（0700，属于宿主用户；属主不对时报错退出），bind mount 到 `/run/todex-ipc`。所有平台都给服务加标签 `io.todex.instance=<name>`。`up`/`status` 打印 socket 路径。`/run/*` 仍是用户 `--mount` 的保留目标。
- **compose：** 同样的 bind mount，宿主路径 `${TODEX_IPC_DIR:-${HOME}/.config/todex-container/default/ipc}`，`create_host_path: true`；标签 `io.todex.instance=${TODEX_INSTANCE:-default}`。README 要求首次启动前 `mkdir -p -m 700`，否则 Docker 以 root 创建该目录及缺失的上级目录（entrypoint 之后会修正目录本身，修不了上级）。
- **发现：** Desktop 扫描 `~/.config/todex-container/*/ipc/agentd.sock`，并结合 `docker ps --filter label=io.todex.instance`。
- **信任模型：** 后端在 accept 时比对 `peer_cred().uid()` 与自身 euid，不一致直接断开。`todexc` 已把容器用户的 UID 对齐宿主用户，所以宿主用户能连、其他用户（包括容器里的 root）不能。local-admin 的批准仍要求请求的验证码，经 socket 发起的配对请求记录 `peerAddress: "ipc"`。
- **不适用的场景：** Docker Desktop（macOS、Windows）的文件共享无法把 Unix socket 传到宿主机，`todexc` 在 macOS 上不挂载，Desktop 走 TCP + `todexc pair`/`docker exec … pair approve`。rootless Docker、Podman、`userns-remap` 下容器 UID 与宿主 UID 不同，socket 会拒绝宿主用户，Desktop 同样回退到 TCP。socket 路径超过 `sun_path` 上限（107 字节）时 `todexc` 给出警告。
- **验证：** `tests/todexc.sh` 检查 Linux 上的挂载、0700 目录和标签，以及 macOS 上没有挂载；`tests/smoke.sh` 从宿主机经 socket 访问 `/v2/version`、`/v2/local-admin/status`（`deployment=container`、`configEditable=false`），确认 TCP 上没有 local-admin、容器内 root 和其他 UID 被拒绝；`tests/pairing-e2e` 经 socket 完成 create → reveal → local-admin 批准 → poll。镜像里的后端不支持 IPC 时，这两项测试跳过。

## 4. 实施步骤

### 步骤 0：仓库与规范

- **交付结果：** 本仓库有 `AGENTS.md`（已完成）和本计划；`TodeX_backend`、`TodeX_desktop`、`TodeX_web` 的 `AGENTS.md` 兄弟仓库列表里加上 `../TodeX_container`。
- **验证方式：** `git diff --check`；各仓库分别提交、推送。
- **前置：** 你在 GitHub 上创建 `youtonghy/TodeX_container`，或同意由我用 `gh repo create` 创建（对外操作，需要你确认）。

### 步骤 1：基于现有后端的可运行镜像（MVP）

- **交付结果：** `docker compose up -d` 起来的容器能被 Desktop 配对（用 `docker exec -it -u todex todex todex-agentd tui` 批准），能在原路径挂载的目录里跑完一次 Codex 会话。
- **涉及范围：** `Dockerfile`、`todex-entrypoint`、`compose.yaml`、`compose.build.yaml`、`.env.example`、`tests/smoke.sh`。
- **完成标准：** 完成标准 1、5、6 成立；`doctor providers` 能看到预装的 CLI。
- **验证方式：** `hadolint`、`shellcheck`、两个架构的 `docker buildx build`、`tests/smoke.sh`、手动配对一次。
- **待验证：** 在 `serve` 模式下，TUI 的设备面板能否批准（不依赖 `daemon.json`）；各 CLI 的安装方式和 arm64 支持；UID 重映射在 Docker Desktop for Mac 上的表现。

### 步骤 2：后端的容器支持

- **交付结果：** 3.4 中后端的全部 CLI、配置和 HTTP 字段。
- **涉及范围：** `src/main.rs`、`src/config.rs`、`src/device_pairing.rs`、`src/devices.rs`、`src/provider/cli_manager.rs`、`src/server/v2.rs`、`src/update.rs`、`src/server_runner.rs`、`docs/*`。
- **实施方式：** CLI 复用 TUI 和 `cli_manager` 的已有函数，不复制逻辑；新字段都带 `skip_serializing_if`；路径映射在加载配置时校验。
- **完成标准：** 默认配置下 `/v2/version`、`/v2/providers/versions` 的输出除了新增的 `deployment: "host"` 外不变；`pair approve` 的成功、过期、匹配不唯一、用户不对四种情况都有测试。
- **验证方式：** `cargo fmt --check`、`cargo clippy`、`cargo test`（单元测试 + `tests/e2e_api.rs` 中 pair/version 的用例），推送后 `checks.yml` 通过，然后发布后端版本。

### 步骤 3：镜像切换到新后端，加入 `todexc` 和发布流水线

- **交付结果：** `todexc up/pair/devices/mount/upgrade/...`；`TODEX_EXTRA_AGENTS`；`image.yml` 在原生 amd64 和 arm64 runner 上构建、冒烟测试、合并 manifest 并推送。
- **完成标准：** 完成标准 1、2、3、7 成立；`tests/pairing-e2e/` 用 `TodeX_protocol` 的配对实现无头完成“create → reveal → `pair approve` → poll”，并用签名请求读到 `deployment` 和 `pathMappings`。
- **依赖：** 步骤 2 的后端发布。

### 步骤 4：协议层与客户端（D1–D3）

- **交付结果：** 容器配对提示、同步配置入口卡片、“随镜像更新”标记；Desktop 和 Web 同步实现。
- **验证方式：** Protocol `npm run test:unit && npm run check:protocol && npm run typecheck`；Desktop `pnpm typecheck && pnpm test:updates`；Web `pnpm lint && pnpm typecheck && pnpm build`；对容器手动走一遍配对和同步（完成标准 3、4）。
- **依赖：** 步骤 2（字段）。可以和步骤 3 并行。

### 步骤 5：路径映射（D4–D5）

- **交付结果：** Windows 或自定义挂载下的“本地选择”和“打开 / 在文件夹中显示”；`todexc` 对非原路径挂载自动生成映射；compose 示例加上 Windows 写法。
- **验证方式：** 协议层路径映射单元测试（POSIX、Windows、段边界、最长前缀）；Desktop 新增 `scripts/path-mapping.test.ts`；手动用 `/workspace/<名字>` 映射建工作区并打开文件。
- **依赖：** 步骤 2、4。

### 步骤 6：文档与端到端验收

- **交付结果：** 本仓库 README（中英文）：快速开始、配对、同步、挂载、升级、备份、安全说明；后端和 Desktop 文档的交叉链接。
- **验证方式：** 在干净机器上按 README 从零走完完成标准 1–6。

## 5. 风险、边界与交付

### 5.1 真实风险

| 风险 | 影响 | 应对 |
| --- | --- | --- |
| 闭源 CLI 的再分发许可 | 公开镜像可能违反厂商条款 | 第 6 节决策；实施前核对每个 CLI 的许可证 |
| 厂商安装脚本变化，或没有校验和 | 构建失败或不可复现 | 尽量用带完整性校验的 npm 包并固定版本；CI 冒烟测试；构建失败时直接报错，不静默跳过 |
| 宿主机 UID 与容器不一致 | 挂载目录不可写，或文件归属错误 | `todexc` 自动传 UID/GID；entrypoint 重映射；拒绝 root。rootless Docker/Podman 的 UID 映射不同，文档里写明 `--userns=keep-id` 等做法 |
| bridge 网络下所有请求的来源都是网关 IP | 按来源 IP 的配对限流被共享；审计日志里看不到真实来源 | 单用户场景可以接受，文档说明；Linux 上可选 `--network host` |
| 同步过来的配置里有宿主机绝对路径（如 MCP 命令 `/home/jh/...`） | 在容器里找不到 | 现有的 `absolutePath` 提示；文档说明；重写路径不在本次范围 |
| home 卷里的 `agent-providers.json` 是明文（0600） | 卷备份里含密钥 | 与宿主机安装一致；文档提醒 |
| 升级或改挂载要重建容器 | 正在运行的 Agent 回合中断 | `todexc` 执行前提示；会话运行时本身支持重连 |
| 自更新被误开 | 守护进程退出，容器反复重启 | 环境变量关闭、二进制 root 属主、`deployment=container` 时 `update` 拒绝，三层保护 |
| 局域网暴露 | 攻击面变大 | 默认只绑回环；开启后仍要求配对和加密 |
| Agent 对挂载目录有完全读写权限 | 误操作会改坏工作目录 | 容器能隔离宿主机的其余部分，但不保护挂载目录；文档写明 |
| 镜像体积（预计 1–1.5 GB） | 首次拉取慢 | 非必需工具不进镜像；浏览器做成单独变体（后续） |

### 5.2 明确不包含

- 一次性配对令牌 / 配对链接自动批准。可以作为配对 v3 的扩展后续加入：令牌只通过 `docker exec` 展示，不写日志；客户端用令牌对 transcript 做 HMAC，与传输公钥绑定；只能用一次，10 分钟过期。
- Desktop 直接管理 Docker（在界面里一键创建容器、管理挂载）。
- 容器内的 Agent 浏览器（Xvfb + Chrome for Testing）和 Computer Use。
- Windows PowerShell 版 `todexc`（Windows 先用 compose）。
- 不经过 Desktop 的离线配置包导入，以及同步时重写路径。
- Kubernetes/Helm、云端托管、TLS 监听。
- Gemini CLI 适配器（需要后端新增 provider 或 ACP profile）。

### 5.3 交付内容

- 本仓库：镜像、入口脚本、`todexc`、compose、测试、CI、README。
- 后端：`pair`、`devices`、`providers install` 三组 CLI，四个配置项，`/v2/version` 和 `/v2/providers/versions` 的追加字段，以及文档。
- 协议层：类型和路径映射函数，附测试。
- Desktop/Web：D1–D5。
- 各仓库分别提交和推送；后端 CI 通过；镜像发布记录。

## 6. 需要确认的产品决策

### 1. 公开镜像是否预装闭源的 Agent CLI

**计划当前采用：** 公开镜像预装开源许可的 CLI（Codex、OpenCode、Pi，实施前逐个核对许可证）。Claude Code 不放进镜像层，由 entrypoint 在首次启动时自动安装到 home 卷（默认 `TODEX_EXTRA_AGENTS=claude-code`），之后持久化，并且可以在 Desktop 里升级。本地构建可以用 `--build-arg PREINSTALL_AGENTS=...` 把它也预装进去。

**需要你确认：** 发布到 `ghcr.io` 的公开镜像里，是否直接包含 Claude Code（以及 Grok、Devin、Antigravity 等闭源 CLI）的二进制。

**为什么必须确认：** “自带主流 Agent”最直接的做法是全部预装，但 Claude Code 等不是开源许可证发布的，在公开镜像里再分发可能违反厂商条款。这是法律和风险接受层面的选择，无法从代码推断。

**如果选择其他方案：**

- B：全部预装进公开镜像。首次启动更快、离线可用，许可风险由你承担。改动步骤 1、3 的 Dockerfile 和第 2.5 节。
- C：全部在首次启动时安装，镜像不预装任何 CLI。镜像最小，没有许可问题，也不需要后端的 `managedBy`；但首次启动要联网、耗时几分钟。删掉 3.4 中的 `IMAGE_CLI_DIR` / `managedBy` 和 D3。

**已确认：** 采用计划建议（2026-10-23）。
