# Hermes plugin install: speed + reliability optimization

**Date:** 2026-06-03
**Status:** design → implementation
**Scope:** `clawchat-plugin-install-cli/` (primary), `docs/install-dev.md`, optional `clawchat-plugin-hermes-agent/`. All work on each repo's `dev` branch.

## Goal

Make `hermes` plugin install + activate reliably complete **under 3 minutes**, faster on a
healthy network and **fail-fast-then-retry on a broken network**. Push every decision that
the CLI can make into the CLI itself, minimizing what the install-time LLM must reason about.

Baseline (post-commit `ce3825e`): e2e usercase passes at ~75s against a 180s budget. This
work removes the remaining redundant network round-trip, hardens git against hangs, tightens
broken-network timeouts, and lets the CLI self-verify success instead of relying on the agent.

## Current install path (what `install-dev.md` actually runs)

```
npx @clawling/clawchat-plugin-install-cli@dev install \
    --target hermes@https://github.com/clawling/clawchat-plugin-hermes-agent.git#dev ...
```

→ `installHermesPlugin` → `installHermesFromRef` (because `ref` is set), which does:

1. `curl` `raw.githubusercontent.com/.../dev/plugin.yaml`  ← **network round-trip #1**
2. `hermes --version` (local) + host-compat check
3. `git clone --depth 1 --single-branch --branch dev <repo>`  ← **network round-trip #2 (same repo)**
4. `hermes plugins install file://<clone> --force --enable`

`plugin.yaml` is present inside the clone from step 3, so step 1 is redundant on this path.

## Changes

### 1. Ref path: clone-first, drop the redundant `curl` (biggest win)
Reorder `installHermesFromRef` so it clones once, then reads `plugin.yaml` from the local
checkout for the version + host-compatibility check (preserving the guard *before*
`hermes plugins install`). Removes one GitHub round-trip and one flaky-network failure point
on the exact path used in production install docs.

Implementation: give `installViaLocalClone` an optional `afterClone(dest)` hook invoked
between a successful clone and `hermes plugins install`. The ref path passes a hook that reads
`<dest>/plugin.yaml`, runs `assertVersionSatisfiesRange`, and captures the version for
reporting. Canonical (non-ref) path is unchanged — there the `curl` is still useful (it lets
the CLI decide skip/update *without* cloning).

### 2. Harden git against interactive hangs
Add an optional `env` to `CommandOptions` in `run.ts`. For the clone, set
`GIT_TERMINAL_PROMPT=0` (plus `-c credential.helper=`) so auth / bad-branch failures error
out immediately and deterministically instead of blocking on a credential prompt until the
SIGKILL timeout. The retry classifier already lists "terminal prompts disabled" as
non-retryable, confirming this is the intended behavior.

### 3. Tighten broken-network fast-fail (goal: 缩减超时进行重拾)
`GIT_CLONE_TIMEOUT_MS` 20s → 15s; `http.lowSpeedTime` 10 → 8. Keep 2 retries + backoff.
Broken-network clone worst case: 15×3 + 6s backoff ≈ 51s (was 66s). Combined with removing
the redundant `curl` (~15–45s), the ref-path broken-network worst case drops from ~98–111s to
~51–56s — well under budget, retries intact.

### 4. (dropped) CLI post-install verify
Considered running `hermes plugins list` after install to confirm `clawchat` is enabled.
Dropped: `hermes plugins install` already exits non-zero on failure and the CLI already turns
that into a thrown error, so install failure is *already* detected deterministically. A
`plugins list` re-check would not have caught any historical failure (those were network /
PATH / config-mount / gateway-restart issues) and would force brittle stateful mocks. Skipped
to keep the change focused.

Note: `run.ts` uses `spawnSync`, which blocks the event loop, so preflight calls cannot be
truly parallelized via `Promise.all`. The latency wins come solely from removing the redundant
`curl` round-trip and tightening timeouts — not from concurrency.

### 5. Trim `docs/install-dev.md`
With the CLI self-verifying and self-deciding, slim the agent-facing doc: keep the
single-block venv-prelude install/activate commands (still required for PATH), drop guidance
that duplicates CLI-internal decisions, and make the happy path crisper so the LLM runs fewer
commands and does less branching.

### 6. Python plugin (`clawchat-plugin-hermes-agent`)
Activation already fail-fasts (15s timeout, 20s ceiling) and safely retries only
`connect_failed` (single-use-code safe), with the `CLAWCHAT_BASE_URL` precedence fix in
`bbd8a31`. Left **unchanged** to avoid regression risk; the speed/reliability wins are in the
CLI. (Permission to touch its `dev` branch is held in reserve.)

## Non-goals
- No change to the activation wire protocol or single-use-code retry semantics.
- No change to OpenClaw install path.
- No change to the e2e cluster/pod topology.

## Validation
1. `pnpm test` (vitest) in `clawchat-plugin-install-cli` — extend `hermes.test.ts` to cover:
   clone-first ordering (no `curl` on ref path), version check reads local `plugin.yaml`,
   `GIT_TERMINAL_PROMPT=0` passed, tightened timeout constant, post-install verify pass/fail.
2. Publish CLI `@dev`, then run `e2e/usercase/run-hermes-install-activate.sh` against the dev
   cluster and confirm PASS under 180s (requires `.env` with `CLAWCHAT_JWT` + `LLM_API_KEY`).
3. `script/upload-install-dev.sh` to publish the trimmed runtime doc.

## What actually shipped (post-validation addendum)

End-to-end validation on the dev cluster surfaced root causes the static design
missed. Final shipped set (CLI `@dev` = `0.2.0-dev.5`):

1. **Ref path clones once, reads `plugin.yaml` from the checkout** (as designed) —
   removed the redundant `curl`.
2. **`GIT_TERMINAL_PROMPT=0` + tightened clone timeouts** (20s→15s, lowSpeedTime
   10→8) (as designed).
3. **Clone-retry now resets `dest` before each attempt** (NEW — the decisive fix).
   A slow/SIGKILL'd clone left a partial dir; git rejected every retry with
   "destination path already exists", so on a cold/slow network the whole install
   failed and the agent had to re-run the entire `npx`. `fs.rmSync(dest)` before
   each attempt makes the retry budget actually usable; cold install now
   self-recovers in one `npx` call (~30s).
4. **`install --activate <code>`** (NEW) — folds activation into the install
   command (`hermes clawchat activate`, single-use, never retried). Collapses the
   Hermes happy path to one agent tool call so activation lands early regardless
   of later LLM rambling. `install-dev.md` rewritten: Hermes = one block, step 3
   is OpenClaw-only / Hermes-repair.
5. **e2e harness hardened** (`e2e/usercase/run-hermes-install-activate.sh`):
   measured the dominant cost/flakiness is the install-time LLM turn — the weak
   test model (`deepseek-v4-flash`) intermittently *hangs while emitting the tool
   call* (`activations=0`, full-budget timeout). Fix = bounded agent turn +
   read-only activation poll + **retry on stall** with a fast **hung-kill** (≥30s
   with zero install activity → kill & retry). Pure CLI path is ~12s warm / ~30s
   cold; full e2e now **10/10 PASS, ~35–158s** (was flaky, sometimes 177s/fail).

Pure-CLI timings (LLM bypassed, in-pod): install 12s warm / 30s cold (one
self-recovering retry), `activate` 1s, gateway connect ~6s.

The Python plugin was left unchanged, as designed.

## Adversarial review (workflow)
After implementation, run a `Workflow` that fans out independent reviewers over the diff:
correctness, broken-network timeout math, test coverage, "no LLM-side decisions" compliance,
and docs/CLI consistency — each verifying adversarially before the change is considered done.
