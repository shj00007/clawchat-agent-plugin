# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

`clawchat-agent-plugin` is an **aggregator git repo** that bundles three independent submodules. There is **no top-level build, test, or lint** — every command runs inside a submodule. Edit inside each submodule; this parent repo only tracks pinned submodule commits in `.gitmodules`. When using a git worktree to execute a plan, create it **inside the relevant submodule** (each leaf is its own git repo) — the aggregator root is not where code work happens.

| Submodule | Language / toolchain | Role | Published as |
|-----------|----------------------|------|--------------|
| `openclaw-clawchat/` | TypeScript (npm + Vitest) | OpenClaw **channel** plugin. Owns a Protocol-v2 WebSocket client + REST surface; persists state in plugin-owned SQLite. | npm `@newbase-clawchat/openclaw-clawchat` |
| `hermes-clawchat/` | Python ≥3.11 (uv + pytest) | Hermes Agent **gateway platform** plugin. Registers `clawchat` platform via `ctx.register_platform(...)`; no DB, only file-backed memory. | wheel `clawchat-gateway`; Hermes plugin id `clawchat` |
| `openclaw-clawchat-cli/` | TypeScript (pnpm workspaces + Vitest) | CLI installer that delegates to each host's plugin manager. Two packages: `packages/cli` (published) + `packages/core` (workspace-private, inlined). | npm `@newbase-clawchat/clawchat-cli` |

## Architecture: two peer adapters + one installer

`openclaw-clawchat` and `hermes-clawchat` are **peer adapters of the same ClawChat Protocol v2 contract** (WebSocket + a small REST surface) — one in TypeScript for OpenClaw, one in Python for Hermes. They expose the **same 22 `clawchat_*` agent tools** and onboard the same way (exchange a one-time code at `POST /v1/agents/connect`). `openclaw-clawchat-cli` is the end-user installer for both (`install --target openclaw|hermes`).

The two adapters share a near-identical module layout under different file extensions (e.g. `protocol`, `inbound`, `outbound`, `streaming`, `tools`, `media-runtime`, `storage`, `config`, `profile-sync`). The TS source is in `src/`; the Python source is in `clawchat_gateway/`.

Full side-by-side comparison: `docs/openclaw-vs-hermes.md`.

## Two load-bearing constraints

**1. Adapter parity is a maintenance obligation.** Because one contract is implemented twice, changing one adapter usually means mirroring the change in the other. The shared surfaces that must stay in sync:
- **Wire protocol** — update each repo's local `docs/client-integration.md` first, then `protocol`/`inbound` in both.
- **Tool set** — the 22 tools across `openclaw.plugin.json` + `src/tools.ts` ↔ `plugin.yaml` (`provides_tools`) + `clawchat_gateway/plugin_tools.py`.
- **Prompts** — `prompts/platform.md`, `default-owner-behavior.md`, `default-group-bio.md`.
- **Bundled skill** — `skills/clawchat/SKILL.md`.
- **Memory contract** — `owner.md` / `users/` / `groups/` layout; canonical write-up in `openclaw-clawchat/docs/clawchat-memory.md`.
- **Connection defaults** — reconnect / heartbeat / ack / streaming (mind the `forwardThinking` vs `show_think_output` divergence noted in the comparison doc).

**2. The two submodule plugins must stay decoupled from the ClawChat server (`clawchat-msghub`).** Inside `openclaw-clawchat/` and `hermes-clawchat/`, the authoritative docs (README, AGENTS.md, `docs/*.md`) must **not** reference `clawchat-msghub`, server binaries, or server-internal tech. Each plugin only knows "the WebSocket docking protocol", documented in its **local** `docs/client-integration.md` — that local doc is the contract to update when the protocol changes. Sibling-plugin cross-references are fine; only server coupling is banned. The **aggregator-level** `docs/` (this repo's own `docs/`) MAY mention msghub as ecosystem context.

## Docs-as-source-of-truth

Each submodule keeps deep docs in its own `docs/` and treats them as authoritative; the orientation files (`AGENTS.md`, README) deliberately stay thin. Before changing a feature, read the matching `docs/` page; after changing behavior, update that page in the **same change set**. Per-submodule entry points:
- `openclaw-clawchat/AGENTS.md` → `docs/README.md`, reference `docs/openclaw-clawchat.md`
- `hermes-clawchat/README.md` → `docs/README.md`, `docs/architecture.md`
- `openclaw-clawchat-cli/AGENTS.md` → `docs/architecture.md`, `docs/development.md`

## Commands

### openclaw-clawchat (npm)
```bash
npm test                                   # Vitest; tests live next to source (*.test.ts)
npm test -- src/file.test.ts -t "name"     # single test
npm run typecheck                          # tsc --noEmit
npm run build                              # tsc -p tsconfig.build.json → dist/
```
Dev entrypoint stays `index.ts`; npm installs use the compiled `dist/` entrypoint. High-value contract tests: `src/manifest.test.ts`, `src/tools.test.ts`. E2E flows under `.e2e/` (read `.e2e/docs/install-clawchat-plugin-e2e.md` first): `npm run test:e2e:install-clawchat-plugin[:smoke|:agent|:agent:smoke]`. Optional OpenClaw host source for API lookup: `npm run dev:openclaw-source` (clones into git-ignored `tmp/openclaw/` — a reference only, never patch it).

### hermes-clawchat (uv)
```bash
uv pip install -e ".[test]"   # install with test extras
uv run pytest                 # tests/ is .gitignore'd — present only in dev checkouts
uv run pytest tests/test_x.py
```
The published checkout intentionally excludes `tests/`. Hermes host source lookup is documented in `docs/hermes-source-lookup.md` (do not guess host semantics).

### openclaw-clawchat-cli (pnpm)
```bash
pnpm install
pnpm typecheck    # -r across packages
pnpm test         # -r; Vitest per package, incl. install-script integration tests
pnpm build        # -r; tsdown
pnpm --filter @newbase-clawchat/clawchat-cli test   # single package
```
No dedicated linter — consistency with neighbouring files is the bar. Conventional Commits with a package scope, e.g. `feat(cli): ...`, `fix(core): ...`. Installer logic lives in `packages/core/src/installers/` (`openclaw.ts`, `hermes.ts`). The runtime install guide consumed by end-users/agents is `install.md` (also published to R2).
