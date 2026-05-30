# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

`clawchat-agent-plugin` is an **aggregator git repo**: it owns no application code itself, only a `docs/` tree and three submodules pinned in `.gitmodules`. There is **no top-level build, test, or lint** — every command runs inside a submodule.

## Directory structure

```
clawchat-agent-plugin/              # aggregator repo (git@github.com:shj00007/clawchat-agent-plugin.git)
├── .gitmodules                     # pins the three submodules below
├── CLAUDE.md
├── docs/                           # aggregator-level docs (ecosystem context; MAY mention msghub)
│   ├── README.md / README.zh.md
│   └── openclaw-vs-hermes.md/.zh.md  # side-by-side comparison of the two adapters
├── clawchat-plugin-openclaw/       # submodule
├── clawchat-plugin-hermes-agent/   # submodule
└── clawchat-plugin-install-cli/    # submodule
```

Each submodule is an independent repo in its own language. Read its local `CLAUDE.md` / `AGENTS.md` / `README.md` before working inside it.

| Directory | Language / toolchain | Role | Published as |
|-----------|----------------------|------|--------------|
| `clawchat-plugin-openclaw/` | TypeScript (npm + Vitest) | OpenClaw **channel** plugin. Protocol-v2 WebSocket client + REST surface; plugin-owned SQLite state. | npm `@newbase-clawchat/openclaw-clawchat` |
| `clawchat-plugin-hermes-agent/` | Python ≥3.11 (uv + pytest) | Hermes Agent **gateway platform** plugin. Registers a `clawchat` platform via `ctx.register_platform(...)`; plugin-owned SQLite (operational state + activation tokens) plus file-backed memory. | wheel `clawchat-gateway`; Hermes plugin id `clawchat` |
| `clawchat-plugin-install-cli/` | TypeScript (pnpm workspaces + Vitest) | CLI installer that delegates to each host's plugin manager. `packages/cli` (published) + `packages/core` (workspace-private). | npm `@newbase-clawchat/clawchat-cli` |

## Where to read (project-internal matters)

For anything *inside* a submodule — its architecture, wire protocol, tool set, build/test commands, parity obligations, server-decoupling rules — read that submodule's own docs (start from its `AGENTS.md`/`README.md`, which point into its `docs/`). They are authoritative; don't rely on this aggregator file. Cross-cutting/ecosystem matters live in this repo's own `docs/`.

## Git structure

Four independent repos, all on branch `main`:

| Repo | Remote | Tracked here as |
|------|--------|-----------------|
| aggregator (this repo) | `git@github.com:shj00007/clawchat-agent-plugin.git` | — |
| openclaw plugin | `git@github.com:clawling/clawchat-plugin-openclaw.git` | submodule `openclaw-clawchat` → `clawchat-plugin-openclaw/` |
| hermes plugin | `git@github.com:clawling/clawchat-plugin-hermes-agent.git` | submodule `hermes-clawchat` → `clawchat-plugin-hermes-agent/` |
| install CLI | `git@github.com:clawling/clawchat-plugin-install-cli.git` | submodule `openclaw-clawchat-cli` → `clawchat-plugin-install-cli/` |

Note the submodule **name** in `.gitmodules` differs from its folder **path** (e.g. name `openclaw-clawchat`, path `clawchat-plugin-openclaw/`). The aggregator only stores each submodule's pinned commit SHA, never its files.

### How to update and commit

**Real code/doc changes always happen inside a submodule** — never commit application code to the aggregator.

1. **Edit + commit in the submodule.** `cd` into the submodule, make changes, commit, and push to its own remote on `main`:
   ```bash
   cd clawchat-plugin-openclaw
   # ...edit, run that submodule's own tests...
   git add -p && git commit -m "feat: ..." && git push origin main
   ```
2. **Bump the pin in the aggregator.** Pushing the submodule moves its SHA, so the parent now shows the submodule as modified. Record the new pin from the aggregator root:
   ```bash
   cd ..                               # back to aggregator root
   git add clawchat-plugin-openclaw    # stage the moved pointer
   git commit -m "chore: bump openclaw submodule pin"
   git push origin main
   ```
   Aggregator-only commits touch `.gitmodules`, the pinned SHAs, `docs/`, or this file.

### Cloning & refreshing

```bash
git clone --recurse-submodules git@github.com:shj00007/clawchat-agent-plugin.git
git submodule update --init --recursive   # after a plain clone
git submodule update --remote             # fast-forward each submodule to its remote main
```

When using a git worktree to execute a plan, create it **inside the relevant submodule** (each leaf is its own repo) — the aggregator root is not where code work happens.
