# Design: installer base-URL flags + `@`-target test-branch installs

Date: 2026-06-03
Scope: `clawchat-agent-plugin` workspace — touches three submodules:
`clawchat-plugin-install-cli` (most of the work), `clawchat-plugin-hermes-agent`,
`clawchat-plugin-openclaw`.

## Goal

Let an operator/agent, at install time, point a freshly-installed ClawChat plugin at
a non-default backend (a **dynamic** host:port supplied per-install — never hardcoded in
plugin code or docs) **and** install a test branch/version of the plugin — in one
`npx … install` call.

> Convention: concrete hosts in this doc are placeholders (`<api-host:port>` etc.). The
> real backend address is dynamic and provided at install time; it must not appear in
> plugin source, plugin READMEs, or the install-CLI README. Plugin **defaults** stay
> `app.clawling.com`. (`docs/install-dev.sh` is a **template** and is exempt — leave it
> as-is.)

Two capabilities:

1. **Base-URL overrides** written to the agent host *before* the plugin is installed,
   so the plugin reads them at startup. Three flags, three endpoints:
   - `--apibaseurl`  → REST/API base (`/v1/*`, **activation/connect-code redemption**, profile, friends, moments, conversations, avatar) → `base_url` / `CLAWCHAT_BASE_URL`
   - `--wsbaseurl`   → WebSocket (Protocol v2 messaging) → `websocket_url` / `CLAWCHAT_WEBSOCKET_URL`
   - `--mediabaseurl`→ media upload/download (`/media/upload`) → **new dedicated** media slot
2. **`@`-suffixed target** to install a test branch/version:
   - `--target openclaw@<ref>` → install npm dist-tag/version `<ref>`
   - `--target hermes@<giturl>[#branch]` → install from that git url/branch

## Why three endpoints (not two)

The plugins' *current code* assumes REST + WS + media all live on one host
(`app.clawling.com`): REST is `{base_url}/v1/*`, WS is `{websocket_url}`, and media is
**derived** as `{base_url|ws-netloc}/media/upload`. A split topology puts them on three
distinct host:ports — REST (member-backend), WS (msghub), media (msghub) — so:

- `--mediabaseurl` must **split media off** from `base_url` (today it can't be set independently).
- `--apibaseurl` is required because `/v1/agents/connect` (activation itself) rides `base_url`;
  overriding only ws+media would leave activation pointing at the default backend.

Endpoint inventory (verified in code):

| # | Slot | Used for | Today's source | Default |
|---|------|----------|----------------|---------|
| 1 | `base_url` (REST `/v1/*`) | activation/connect, profile, friends, moments, conversations, avatar upload-url | `CLAWCHAT_BASE_URL` → config → default | `https://app.clawling.com` |
| 2 | `websocket_url` | WS messaging | `CLAWCHAT_WEBSOCKET_URL` → config → default | `wss://app.clawling.com/ws` |
| 3 | media | `/media/upload` (up/download) | **derived** from base/ws netloc (no own config) | derived |

## Decisions (locked with user)

- **Normalization — assume TLS.** Bare `host:port` is normalized by the installer; a full
  schemed URL is written verbatim (lets caller force `ws://`/`http://` for non-TLS hosts).
  - `--wsbaseurl host:port`    → `wss://host:port/ws`  (WS gets `/ws` appended)
  - `--apibaseurl host:port`   → `https://host:port`   (no path; plugin appends `/v1/...`)
  - `--mediabaseurl host:port` → `https://host:port`   (no path; plugin appends `/media/upload`)
- **Dedicated media config** in both plugins: new slot used if present, else fall back to
  today's derive-from-base behavior. WS + REST need **no plugin code change** — both already
  resolve `config → env → default`, so writing the values is enough ("hard-wired first").
- **Write locations** (pre-install, idempotent upsert, separate from activation-managed token state):
  - **Hermes** → `$HERMES_HOME/.env` (default `~/.hermes/.env`): `CLAWCHAT_BASE_URL`,
    `CLAWCHAT_WEBSOCKET_URL`, `CLAWCHAT_MEDIA_BASE_URL`. Already in the plugin's resolution
    chain (above config.yaml/defaults).
  - **OpenClaw** → `openclaw.json` `channels["clawchat-plugin-openclaw"].{baseUrl, websocketUrl, mediaBaseUrl}`.
    No `.env` mechanism exists for OpenClaw; this config file is the plugin's top-priority
    source and activation only writes token/userId there, so URLs won't be clobbered.

## Component design

### A. install-cli (`clawchat-plugin-install-cli`)

New shared module `packages/core/src/baseurl/`:

- `normalize.ts` — `normalizeWsUrl(input)`, `normalizeHttpUrl(input)`.
  Has-scheme check `^[a-z][a-z0-9+.-]*://` → verbatim (trim trailing `/` for http); else apply
  the TLS-assuming rule above.
- `target.ts` — `parseTarget(value): { host: ClawchatTarget; ref?: string }`. Split on the
  **first `@`** (host never contains `@`, so unambiguous even though git URLs sit on the right).
  Validate `host ∈ {openclaw, hermes}`. Also `hermesRawYamlUrl(ref): string | null` — derive the
  `plugin.yaml` raw URL for the compat pre-check from a git ref:
  - `https://github.com/{owner}/{repo}(.git)?(#{branch})?` and `{owner}/{repo}(#{branch})?` →
    `https://raw.githubusercontent.com/{owner}/{repo}/{branch|main}/plugin.yaml`
  - unparseable → `null` (caller skips the version check with a warning, still installs).
- `write-openclaw.ts` — resolve `$OPENCLAW_HOME || ~/.openclaw` + config file; read-modify-write
  JSON, create dir/file/parent objects if absent, preserve other keys.
- `write-hermes.ts` — resolve `$HERMES_HOME || ~/.hermes` + `.env`; upsert each `KEY=value`
  line (replace existing key or append), preserve other lines (tokens). Line format must match
  what `clawchat_gateway.config._read_env_file_value` parses — confirm exact format in impl.

CLI (`packages/cli/src/cli.ts`): add `--apibaseurl`, `--wsbaseurl`, `--mediabaseurl` to **both**
`install` and `update`. Parse `--target` via `parseTarget`. Build a normalized `{apiBaseUrl,
wsBaseUrl, mediaBaseUrl}` (only for flags actually passed) and `ref`; thread into the installers.

Installers (`installers/openclaw.ts`, `installers/hermes.ts`) — extend `InstallerOptions` with
`ref?`, `apiBaseUrl?`, `wsBaseUrl?`, `mediaBaseUrl?`. New flow (both install & update):
1. Upsert provided URLs to the host config (openclaw.json / `.env`) — **before** install.
2. Build the install spec from `ref`:
   - OpenClaw: `@clawling/clawchat-plugin-openclaw` + (`ref ? "@"+ref : ""`).
   - Hermes: `hermes plugins install <ref || "clawling/clawchat-plugin-hermes-agent">`; the
     metadata pre-check uses `hermesRawYamlUrl(ref) ?? HERMES_PLUGIN_YAML_URL`, skipping the
     compat assertion (with a warning) when that returns `null`.
3. Run the host's plugin install as today.

### B. Hermes plugin (`clawchat-plugin-hermes-agent`)

- `config.py`: add `media_base_url` to `ClawChatConfig` —
  `_get_env("CLAWCHAT_MEDIA_BASE_URL")` → config.yaml `extra.media_base_url` → `""` (empty ⇒ derive).
- `media_runtime.py`: `derive_base_url(...)` takes the explicit `media_base_url`; if non-empty use
  it (`rstrip('/')`), else current derive-from-ws/base logic. Callers (upload/download) pass
  `cfg.media_base_url`.

### C. OpenClaw plugin (`clawchat-plugin-openclaw`)

- `config.ts`: add `CLAWCHAT_MEDIA_BASE_URL_ENV`; resolve `mediaBaseUrl` =
  `channel.mediaBaseUrl || env(CLAWCHAT_MEDIA_BASE_URL) || ""`; add to `ResolvedOpenclawClawlingAccount`.
- `api-client.ts`: media upload (and any media fetch) uses `mediaBaseUrl || baseUrl` for
  `/media/upload`; all `/v1/*` keep using `baseUrl`. Thread `mediaBaseUrl` through
  `ApiClientOptions`, the client factory, and the runtime instantiation.

## Data flow (placeholder hosts)

```
npx … install --target hermes@https://github.com/clawling/clawchat-plugin-hermes-agent.git#dev \
  --apibaseurl   <api-host:port> \
  --wsbaseurl    <ws-host:port> \
  --mediabaseurl <media-host:port>
```
1. CLI normalizes → `https://<api-host:port>`, `wss://<ws-host:port>/ws`, `https://<media-host:port>`;
   ref = the git url#dev.
2. Upsert `~/.hermes/.env`: `CLAWCHAT_BASE_URL`, `CLAWCHAT_WEBSOCKET_URL`, `CLAWCHAT_MEDIA_BASE_URL`.
3. Compat pre-check fetches `plugin.yaml` from the `dev` branch raw URL.
4. `hermes plugins install <giturl>#dev --enable`.
5. Plugin starts → reads the three `.env` values (top of its resolution chain) → connects to the
   supplied backend; media uses the dedicated media host.

## Testing

- **core (vitest):** `parseTarget`, `normalizeWsUrl`/`normalizeHttpUrl`, `hermesRawYamlUrl`,
  openclaw.json upsert (tmp dir, preserves other keys + creates missing), `.env` upsert (tmp dir,
  replaces existing key + preserves tokens).
- **hermes (pytest):** `media_base_url` resolution precedence + derive fallback when empty.
- **openclaw (vitest):** `mediaBaseUrl` resolution + fallback to `baseUrl`; media upload hits the
  media host while `/v1/*` hits `baseUrl`.

## Docs

- `docs/install-dev.sh` is a **template — do not modify it** (it already carries the install-time
  flags; the dynamic host is injected/maintained there as the template value).
- Note the new `--apibaseurl` flag, `--wsbaseurl`/`--mediabaseurl`, and `@`-target in the
  install-CLI README, using placeholder hosts only (`<api-host:port>` etc.).

## Out of scope / to confirm during implementation

- No token-refresh or other endpoints — inventory above is complete.
- Exact `.env` line format expected by the hermes reader, and the OpenClaw config filename
  (`openclaw.json` vs `openclaw.config.json`) — verify before writing.
- Assumes `hermes plugins install <giturl>#branch` is accepted by the Hermes host CLI — verify.
```
