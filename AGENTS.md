# Agent Instructions

This repository builds the TodeX agent container image: `todex-agentd` (from `../TodeX_backend`) plus mainstream agent CLIs, ready to pair with TodeX Desktop, receive agent configuration from another TodeX backend, and work in host directories mounted into the container. The design and interface plan is in [docs/PLAN.md](docs/PLAN.md).

## Goal and execution

- Complete the requested outcome within scope. Infer routine details from the repository and conversation; preserve unrelated behavior. Define success by the requested behavior, constraints, and verification evidence.
- Treat action requests (for example, “can you…”, “I want to…”, or “help me…”) as instructions to do the work. Continue through implementation, appropriate verification, and delivery; a plan or capability acknowledgement is not completion.
- Before starting a task that spans modules or repositories, changes product behavior, public interfaces/APIs (including the backend's `docs/API.md`), or data schemas/migrations, touches security, authentication, or permissions, or carries compatibility or deployment risk, invoke the `plan-gate` skill: investigate read-only, present its full plan, and wait for the user to approve or amend it before implementing. For these gated tasks, the approved plan is the reviewable result and authorization covers investigation and planning until approval. Simple, localized, low-risk changes proceed directly without the gate.
- Proceed with routine, reversible work already authorized by the task. Ask only for missing decisions that materially change the outcome and cannot be inferred, or for authorization not already provided. Prepare a concrete, reviewable result before requesting final approval; continue independent work while waiting. Silence is not approval.
- Carry forward prior authorization, constraints, and completed work. Apply follow-up corrections to the active task; answer side questions and then resume unless the user cancels or replaces it.

## Instruction handling

- Follow system and developer instructions first, then explicit user instructions, then applicable repository and skill guidance. Read instructions governing the changed paths and load relevant skills; resolve stale or conflicting guidance against that priority.
- Apart from the `plan-gate` rule above, do not turn routine choices or hypothetical risks into approval gates. If a file or skill causes a pause or departure from the user's intent, link the exact file (for a skill, its `SKILL.md`), quote the rule, and explain its applicability. Distinguish the requirement from your interpretation.
- When editing prompts or guidance, remove redundant or conflicting rules. Define outcomes, constraints, evidence, and completion criteria; prescribe a sequence only when order matters.

## Communication

- Use the user's language unless requested otherwise. Lead with the result or intended action; use plain language, active voice, and technical detail appropriate to the reader.
- Prefer concise paragraphs. Use lists for parallel or sequential information; avoid filler, canned conclusions, invented jargon, and contrastive phrases that introduce an unrequested alternative.
- Start tool-based work with a brief update. During sustained work, report meaningful findings and next steps. Make the final response self-contained: changes, validation, and blockers; distinguish completed work, proposals, and unrun checks.

## Tools, delegation, and verification

- Use `rg` for repository searches. Batch independent searches and reads; sequence dependent operations and conflicting writes. Ground decisions in observed repository and tool results.
- Delegate bounded, independent subtasks when supported by the active harness and parallel work improves speed or quality. Specify scope, file ownership, and expected evidence; review and integrate results. Handle small, tightly coupled edits locally. Keep inter-agent messages readable.
- Reuse repository patterns and inspect the final diff for unintended changes. For documentation-only edits, check content, links, and `git diff --check`.
- Select checks from the affected behavior: `shellcheck` for shell scripts, `hadolint` for the Dockerfile, `docker buildx build` for image changes (both `linux/amd64` and `linux/arm64` when the change is architecture-dependent), and the container smoke test for runtime behavior (health, pairing, provider discovery). Once CI workflows exist, they define the required checks.
- Add tests for meaningful behavior or regression risks. Avoid tests that merely mirror a low-impact edit. Once required checks pass, broaden or repeat them only for new changes, failures, or unresolved concerns; then deliver.
- If blocked, try an available fallback within scope and finish independent work. Report the specific blocker, checks not run, and smallest next step. Never present an attempted tool call or a planned check as successful execution.

## Container image rules

- The image runs the released `todex-agentd` Linux binary, which targets GNU/glibc 2.28+; musl (Alpine) is unsupported by the backend's installer and updater. Use a Debian-based runtime.
- Build `linux/amd64` and `linux/arm64`. Stages that only produce architecture-independent output use `--platform=$BUILDPLATFORM`.
- Pin every downloaded artifact (backend binary, Node.js, agent CLIs) to an explicit version through build arguments and verify it: SHA-256 against the publisher's checksum list where one exists. Record the resolved versions in OCI labels.
- Secrets never enter the image: no credentials in `ARG`, `ENV`, layers, labels, or build logs. Build-time secrets go through BuildKit secrets; runtime credentials come from the persisted home volume or the TodeX config sync, never from the image. Do not echo, log, or hard-code API keys, pairing material, or device secrets in scripts.
- Run agents and the daemon as the non-root `todex` user (the agent browser launches Chromium without `--no-sandbox`). The entrypoint may start as root only to align UID/GID with the host and fix ownership of the home volume, then drops privileges before starting `todex-agentd`. Commands that touch the daemon's control files (`device-pairing/`, `devices.json`) must run as that same user.
- The image is the update unit: keep the daemon's self-update disabled (`TODEX_AUTO_UPDATE=0`) and treat image-provided CLIs as managed by the image.
- Keep the backend's security defaults: device authentication on and transport encryption (`ml-kem-768` by default) required for the container's non-loopback listener. Publish the port on the host loopback by default; LAN exposure is opt-in. Never mount the Docker socket by default.
- Persist state in the `todex` home volume (`~/.todex-agent` data dir and the agents' native config directories). Work directories are bind mounts and must stay at stable paths, because workspace ids hash the backend-side path.
- Use the backend's documented environment variables and API (`../TodeX_backend/docs/BUILD_RUN.md`, `../TodeX_backend/docs/API.md`) rather than reaching into its data files; if the container needs something the backend does not expose, add it to the backend first.
- Follow the TodeX_web image conventions: `compose.yaml` pulls the published image, `compose.build.yaml` overlays a local build, `.env.example` documents settings, a `HEALTHCHECK` hits `/health`, `STOPSIGNAL SIGTERM`, and images publish to `ghcr.io/youtonghy/todex_container` from a manual workflow.

## Provider and model compatibility

- TodeX uses native provider protocols, including Codex app-server. Follow the backend's adapters and [API contract](../TodeX_backend/docs/API.md); OpenAI HTTP API parameters do not establish support in CLI protocols, other providers, or gateways.
- Keep model IDs and agent selections configurable; the image ships CLIs, not model choices or credentials. Agent configuration belongs to the backend's provider profiles and the agents' native config files.
- Validate inputs and outputs at boundaries (entrypoint environment, mounted paths, downloaded artifacts). Check timeouts, retries, and errors; avoid repeating non-idempotent actions during retries.

## Sibling repositories (cross-repo access)

TodeX lives in sibling checkouts under the same parent directory:

- `../TodeX_backend` — Rust backend/API server `todex-agentd` (`docs/API.md` holds the API contract, `docs/BUILD_RUN.md` the runtime configuration)
- `../TodeX_desktop` — Electron desktop client; pairs with the container and runs the config sync
- `../TodeX_web` — Web client; mirrors the desktop renderer and owns the existing Docker image conventions
- `../TodeX_protocol` — shared TypeScript protocol layer (`@todex/protocol`) compiled from source by the desktop and web clients

When a task requires it — aligning the image with the backend's configuration or API, adding a backend or client interface the container needs, or a change that explicitly spans repos — read and edit those sibling repositories directly at their paths, even though they sit outside this repository. Follow each repo's own `AGENTS.md` while working inside it. Commit and push in each repository separately per its Git delivery rules; never mix another repo's changes into this repository's commits.

## Git delivery

- Before starting each task, sync with the remote so the work is based on the latest code: `git fetch`, then fast-forward the current branch to its upstream (`git pull --ff-only`), and create any task worktree from the updated branch. If the fast-forward is blocked (diverged history, or uncommitted changes in the same files), do not stash, reset, or rebase the user's work; base the task on the fetched upstream instead (for example, a worktree from `origin/<branch>`) and mention it in the final response.
- Do every complex task — anything beyond a parameter change or a few localized lines — in a dedicated Git worktree on its own branch, not in the main checkout, which may hold the user's uncommitted work.
- Hand the result back locally: bring the branch into the main checkout (fast-forward or cherry-pick) without modifying the user's uncommitted changes, rerun the relevant checks there, then remove the worktree and its branch.
- After completing each task, create one or more Git commits for the changes made in that task.
- Group commits by change category or repository responsibility when the task includes unrelated changes.
- Run the relevant validation commands before committing whenever practical, and mention any validation that could not be run.
- Push the created commits to the current branch's upstream remote after committing. When a pushed change affects the image and an image build workflow exists, make sure it runs for the pushed commit and watch it until it finishes; fix failures before calling the task complete.
- If committing or pushing is blocked, report the blocker explicitly and leave the working tree status clear in the final response.
- Do not include unrelated local changes in a task commit. Preserve user changes unless the user explicitly asks to modify or discard them.
