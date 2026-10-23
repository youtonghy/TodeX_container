# TodeX agent container

[中文](README.zh-CN.md)

A Docker image with `todex-agentd` (the [TodeX backend](https://github.com/youtonghy/TodeX_backend)) and agent CLIs, ready to pair with TodeX Desktop. Agents run inside the container and work in host directories you mount; the rest of your machine stays out of reach.

Preinstalled: Codex, OpenCode and Pi (openly licensed, versions fixed per image). Claude Code is installed into the container's home volume on first start, because its license does not allow shipping it in a public image. Other TodeX providers (Grok Build, Devin, Antigravity, DeepSeek Harness) install the same way, or from Desktop's CLI management page.

## Quick start (Linux, macOS)

```sh
curl -fsSLO https://raw.githubusercontent.com/youtonghy/TodeX_container/main/bin/todexc
chmod +x todexc
./todexc up --mount ~/projects
```

`todexc` needs Docker with Compose v2. It runs the container as your user ID, publishes the backend on `127.0.0.1:7345`, and mounts `~/projects` at the same path inside the container.

Then, in TodeX Desktop:

1. **Pair.** Settings → Backend connections → Add, enter `http://127.0.0.1:7345`, and start pairing. Desktop shows a verification code. On the host, run `./todexc pair` and enter that code. Desktop connects.
2. **Bring your agent configuration.** If Desktop is also paired with your existing TodeX backend, the new backend offers *Sync agent configuration*. It copies provider accounts (API keys and base URLs), CLI settings and instructions, MCP servers and skills. Nothing on the container is deleted. SSH hosts are left out by default, because the container has none of your private keys.
3. **Work.** Create a workspace and pick a folder under `~/projects` with *Choose locally*. The path is the same in the container, so agent output, git worktrees and *Open* in Desktop all line up.

Subscription logins (ChatGPT for Codex, Claude for Claude Code) may need one login inside the container. Open a terminal on the container backend in Desktop and run `codex login --device-auth` or `claude`, then `/login`. Logins are kept in the home volume.

## `todexc`

| Command | What it does |
| --- | --- |
| `todexc up [--mount PATH[:TARGET]]... [--port N] [--listen ADDR] [--agents LIST] [--ssh-agent] [--tag TAG]` | Create or update the instance and start it. Options are remembered. |
| `todexc pair [CODE]` | Approve a Desktop pairing request (waits for one if none is pending). |
| `todexc devices [revoke ID]` | List paired devices, or revoke one. |
| `todexc mount list\|add PATH[:TARGET]\|rm PATH` | Change mounted directories. The container is recreated; the home volume stays. |
| `todexc upgrade` | Pull the image and recreate the container. |
| `todexc status`, `logs [-f]`, `shell`, `down` | Inspect, open a shell as `todex`, or stop. `down` keeps the home volume. |

Use `--name NAME` before the command to run several instances (each needs its own `--port`). Instance settings live in `~/.config/todex-container/<name>/`.

- `--mount PATH` mounts at the same path. `PATH:TARGET` mounts elsewhere. Every mount is published as a host↔container path mapping, which Desktop uses for *Choose locally* and *Open*.
- `--agents` sets the CLIs installed on first start (default `claude-code`, `""` for none).
- `--ssh-agent` forwards your SSH agent so agents can `git push` with your keys. It is off by default.
- `--listen 0.0.0.0` lets other machines connect. They still have to pair, and all traffic is encrypted.

Mounting a folder after it has been used as a workspace at another path changes the workspace's id; keep mount paths stable.

## Docker Compose

```sh
cp .env.example .env   # set TODEX_WORKDIR, TODEX_PATH_MAPPINGS, TODEX_UID, TODEX_GID
docker compose up -d
docker compose exec -u todex todex todex-agentd pair approve <CODE>
```

`compose.yaml` mounts one directory, at its host path unless `TODEX_WORKDIR_TARGET` is set. For more directories, add a `compose.override.yaml` with extra `volumes` entries and list every mount target in `TODEX_AGENTD_WORKSPACE_ROOTS` (`:`-separated).

### Windows hosts

Windows paths cannot be mounted at the same path, so mount under `/workspace` and declare how the paths correspond. In `.env`:

```sh
TODEX_WORKDIR=C:\Users\me\code
TODEX_WORKDIR_TARGET=/workspace/code
TODEX_PATH_MAPPINGS='[{"hostPath":"C:\\Users\\me\\code","backendPath":"/workspace/code"}]'
```

Desktop uses the mapping to turn a folder picked with *Choose locally* into the container path, and the other way round for *Open*.

## What is in the image

| Component | Location |
| --- | --- |
| `todex-agentd` (release binary, SHA-256 verified) | `/usr/local/bin/todex-agentd` |
| Node.js 24 LTS | `/opt/node` |
| Codex, OpenCode, Pi (`agents/package-lock.json`) | `/opt/todex/agents` |
| git, gh, ssh, ripgrep, jq, python3, curl | system packages (Debian trixie) |

The container runs `todex-agentd serve` as the unprivileged `todex` user under `tini`. At start, the entrypoint aligns `todex` with `TODEX_UID`/`TODEX_GID`, installs `TODEX_EXTRA_AGENTS` that are missing, and drops privileges.

Everything that must survive lives in the `todex` home volume: the backend data dir `~/.todex-agent` (pairing keys, paired devices, provider profiles, conversations), the agents' own config and logins (`~/.codex`, `~/.claude`, `~/.config/opencode`, `~/.pi`, …), and CLIs installed later (`~/.local`).

Updates come from new images. The backend's self-update is off, and image-provided CLIs show *Updated with the image* in Desktop.

## Security notes

- The backend requires paired devices and encrypted transport. By default it is only published on the host loopback.
- Agents have full read/write access to the mounted directories, and network access. The container shields the rest of the host, not the mounted directories.
- Provider API keys are stored in the home volume as owner-only files, the same as a host install. Treat volume backups as secrets.
- The Docker socket is never mounted.

## Development

```sh
# Local image from the released backend
docker compose -f compose.yaml -f compose.build.yaml up -d --build

# Local image with an unreleased backend from ../TodeX_backend
TODEX_AGENTD_SOURCE=source docker compose -f compose.yaml -f compose.build.yaml up -d --build

# Tests against an image
tests/smoke.sh todex_container:local
tests/pairing-e2e/run.sh todex_container:local   # needs ../TodeX_protocol
tests/todexc.sh                                  # launcher only, no Docker needed
```

Pins are build arguments in the `Dockerfile` (`TODEX_AGENTD_VERSION`, `NODE_VERSION`) and `agents/package.json` with its lockfile. `.github/workflows/checks.yml` runs on every push and pull request: shellcheck, hadolint and `tests/todexc.sh` (the launcher, without Docker), then a `linux/amd64` and a `linux/arm64` build on native runners with the smoke and pairing tests. The manual *Publish image* workflow (`image.yml`) reruns those checks and pushes `ghcr.io/youtonghy/todex_container:<backend version>`, `:<backend version>-<yyyymmdd>` and, optionally, `:latest`.

The design and the backend and client interfaces behind this image are described in [docs/PLAN.md](docs/PLAN.md). Contributor rules are in [AGENTS.md](AGENTS.md).
