# OpenClaw conversational-install e2e — design

**Date:** 2026-06-09
**Goal:** An e2e that faithfully replicates the *real user* path for getting an OpenClaw
agent connected to ClawChat — the user already has LLM keys configured and installs the
ClawChat plugin **conversationally** (by talking to the agent, which follows
`install-dev.md` and runs the install/activation itself). Mirrors the existing Hermes
usercase (`e2e/usercase/run-hermes-install-activate.sh`).

## Motivation

The current OpenClaw e2e was driven by hand: I ran `openclaw plugins install` /
`openclaw channels add` directly and patched config manually. That hides whether the
*real* install path works. We want the harness to exercise the path a real user takes, so
real-flow bugs surface in the e2e instead of being worked around.

While building the manual run, two real-path problems were found:

1. **install-cli ordering bug** — `installers/openclaw.ts:installOpenClawPlugin` calls
   `applyBaseUrlOverrides()` (which `writeOpenClawBaseUrls` uses to upsert
   `channels.clawchat-plugin-openclaw.{baseUrl,websocketUrl,mediaBaseUrl}`) **before**
   `openclaw plugins install`. On a host that strictly validates config, `plugins install`
   then fails with `channels.clawchat-plugin-openclaw: unknown channel id` because the
   channel id is not registered until the plugin is installed. This blocks the real
   `npx … install --target openclaw@dev …` path.
2. **`openclaw@dev` did not exist** on npm (only `latest`). Already fixed by publishing
   `@clawling/clawchat-plugin-openclaw@2026.5.13-dev.0` under the `dev` dist-tag (latest
   untouched).

## Part A — fix the install-cli ordering bug

In `clawchat-plugin-install-cli` (`packages/core/src/installers/openclaw.ts`):

- In `installOpenClawPlugin` **and** `updateOpenClawPlugin`, run `openclaw plugins
  install|update <spec>` **first**, then call `applyBaseUrlOverrides(options,
  defaultOpenClawBaseUrlWriter)`. After install the channel id is registered, so writing
  the channel base URLs validates. Base URLs are read at channel-connect time, not at
  install time, so deferring the write has no functional effect.
- Keep `repairStaleOpenClawWorkspace` before the install (unchanged).
- Update/extend the Vitest suite in `packages/core` to assert the order (plugins install
  is invoked before the base-url write), so the regression is locked. `pnpm test` green.

**Publish:** after tests pass, `npm publish --tag dev` a new `clawchat-cli` version (e.g.
`<base>-dev.0`) so `install-dev.md@dev`'s `npx … clawchat-plugin-install-cli@dev` picks up
the fix. **Must not move `latest`** (same discipline as the openclaw@dev publish).

## Part B — `e2e/usercase/run-openclaw-install-activate.sh`

Mirror `run-hermes-install-activate.sh`. Sources `e2e/lib/openclaw-env.sh` and
`e2e/lib/_common.sh`. Reads creds from `e2e/.env` (`CLAWCHAT_JWT`, `LLM_API_KEY`,
`API_BASE`, etc.).

Steps:

1. **Bring up a clean env** (`teardown` + `up`, fresh local-path PVC). Seed config
   adjustments to match a real onboarded OpenClaw gateway deployment:
   - **Remove** the pre-declared `channels.clawchat-plugin-openclaw` block (a freshly
     installed real OpenClaw does not have it; the install writes it).
   - **Set `gateway.mode=local`** (a real gateway deployment is onboarded with this; the
     smoke seed omits it only because it runs `agent --local`). This is simulating a real
     deployment, not bypassing the user flow.
2. **Request a connect code**: `POST $API_BASE/v1/agents/connect-codes` with the test-user
   JWT + `x-device-id`. Parse `.data.code`.
3. **Conversational install + activate**: prefetch `install-dev.md` into the pod (curl -4,
   IPv6 black-hole workaround), then drive the agent:
   `node openclaw.mjs agent --local --session-key <key> -m "<prompt>"`, prompt =
   *"Strictly follow the instructions in the local file `/…/install-dev.md` to install and
   activate the clawchat plugin for OpenClaw. The active code is `<code>`."* The LLM agent
   then runs step 2 (`npx … install --target openclaw@dev …`) and step 3
   (`openclaw channels add --channel clawchat-plugin-openclaw --token <code>`) itself.
   - **Bounded turns + hung-kill + retry** within a hard time budget (reuse the Hermes
     strategy: short per-turn budget, abort a turn that shows no install progress, re-send
     the prompt while the connect code is still unused; install is idempotent).
4. **Start the gateway** (persistent, detached): `nohup node openclaw.mjs gateway` →
   `/home/node/gw.log`. This is how a real OpenClaw deployment runs (the image's default
   cmd is `node openclaw.mjs gateway`).
5. **PASS判定** within a **3-minute hard cap** (from step 3 prompt send): msghub
   server-side `handshake accepted` for the agent user OR gateway-log `handshake_ok`.
   Print connect time.
6. **Timeout/interrupt → FAIL**: kill background turns, dump diagnostics (`gw.log` tail,
   `openclaw plugins list`, agent output tail, msghub tail), exit non-zero.
7. **Cleanup**: `KEEP=1` keeps the env (default, for inspection); `KEEP=0` tears down incl.
   PVC.

Also write `e2e/usercase/run-openclaw-install-activate.md` (usercase doc + known
assumptions: openclaw@dev install path, gateway.mode realism, LLM-jitter retry) and add it
to `e2e/usercase/README.md`.

## Known assumptions to confirm on first run

- The OpenClaw CLI agent (`openclaw agent --local`) has shell/tool access to run `npx` and
  `openclaw` commands (as the Hermes agent does). If not, the conversational install can't
  proceed and the harness reports it.
- `openclaw channels add` does not require `gateway.mode`; the gateway start does (handled
  in step 1).
- `openclaw@dev` resolves to the published dev build with the P0/P1 changes
  (`cap_multi_device:false`, `replay.done` handled) — verifying these on the wire is a
  bonus assertion the harness can log from the msghub handshake / gateway log.

## Out of scope

- Changing the OpenClaw smoke manifest's default cmd to a persistent gateway (the harness
  starts the gateway explicitly; matches the Hermes usercase approach).
- Fixing `install-dev.md`'s OpenClaw `@dev` wording beyond what the dev publish already
  enabled.
