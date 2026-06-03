# Installer base-URL flags + `@`-target test-branch installs — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `--apibaseurl` / `--wsbaseurl` / `--mediabaseurl` flags and `@`-suffixed targets to the ClawChat install CLI so an operator can, in one `npx … install`, point a fresh plugin at a dynamic backend and install a test branch/version; add a dedicated media-base-url slot to both plugins.

**Architecture:** The install CLI (TypeScript, `clawchat-plugin-install-cli`) normalizes bare `host:port` (assume TLS), writes the URLs **before** install — Hermes → `~/.hermes/.env`, OpenClaw → `~/.openclaw/openclaw.json` channel — and installs the ref (`openclaw@<ver>` npm spec / `hermes@<giturl#branch>` git spec). WS+REST need no plugin change (both already resolve config→env→default). Media is the one new plugin slot in both `clawchat-plugin-hermes-agent` and `clawchat-plugin-openclaw`: used when set, else falls back to today's derive-from-base behavior.

**Tech Stack:** TypeScript + Vitest + pnpm workspaces (install CLI); Python + pytest + uv (Hermes plugin); TypeScript + Vitest (OpenClaw plugin). Three independent git submodules under `clawchat-agent-plugin/`.

**Spec:** `docs/superpowers/specs/2026-06-03-install-baseurl-flags-design.md`.

**Dynamic-host rule:** Never write `company.newbaselab.com` into plugin source, plugin READMEs, or the install-CLI README. Examples use placeholders. `docs/install-dev.sh` is a template — do **not** modify it.

---

## File structure

**`clawchat-plugin-install-cli/` (Phase 1)** — all paths under repo root.
- Create `packages/core/src/baseurl/normalize.ts` — `normalizeWsUrl` / `normalizeHttpUrl`.
- Create `packages/core/src/baseurl/target.ts` — `parseTarget` / `hermesRawYamlUrl`.
- Create `packages/core/src/baseurl/write-openclaw.ts` — upsert `openclaw.json` channel URLs.
- Create `packages/core/src/baseurl/write-hermes.ts` — upsert `~/.hermes/.env` URLs.
- Modify `packages/core/src/installers/types.ts` — shared `InstallerOptions` + `BaseUrlOverrides`/`BaseUrlWriter`.
- Modify `packages/core/src/installers/openclaw.ts` — ref-aware spec + write URLs.
- Modify `packages/core/src/installers/hermes.ts` — ref-forced install + write URLs + branch yaml.
- Modify `packages/core/src/index.ts` — export the new `baseurl/*` modules.
- Modify `packages/cli/src/cli.ts` — new flags, core `parseTarget`, thread options.
- Create tests under `packages/core/tests/baseurl/**` and extend `packages/cli/tests/cli.test.ts`.
- Modify the install-CLI README (placeholder hosts only).

**`clawchat-plugin-hermes-agent/` (Phase 2)**
- Modify `clawchat_gateway/config.py` — `media_base_url` field + resolution.
- Modify `clawchat_gateway/media_runtime.py` — `derive_base_url` honors explicit media base; thread through callers.
- Modify `clawchat_gateway/adapter.py` — pass `media_base_url` to media calls.
- Create `tests/test_media_base_url.py`.

**`clawchat-plugin-openclaw/` (Phase 3)**
- Modify `src/config.ts` — `CLAWCHAT_MEDIA_BASE_URL_ENV`, `mediaBaseUrl` on config type/schema/resolved account.
- Modify `src/api-client.ts` — `mediaBaseUrl` option; media upload uses it.
- Modify `src/runtime.ts`, `src/outbound.ts` — pass `mediaBaseUrl: account.mediaBaseUrl`.
- Modify `openclaw.plugin.json` — `CLAWCHAT_MEDIA_BASE_URL` env + `mediaBaseUrl` schema.
- Extend `src/config.test.ts`, `src/api-client.test.ts`.

Phases are independent and each ends green. Within each submodule, commit there and (optionally) bump the aggregator pin per `clawchat-agent-plugin/CLAUDE.md`.

---

# Phase 1 — install CLI

All commands run from `clawchat-agent-plugin/clawchat-plugin-install-cli/`. Test a single core file: `pnpm --filter @clawling/clawchat-plugin-install-core test <relative-path>`. Typecheck: `pnpm typecheck`.

### Task 1: URL normalization (`normalize.ts`)

**Files:**
- Create: `packages/core/src/baseurl/normalize.ts`
- Test: `packages/core/tests/baseurl/normalize.test.ts`

- [ ] **Step 1: Write the failing test**

```typescript
// packages/core/tests/baseurl/normalize.test.ts
import { describe, expect, it } from "vitest";
import { normalizeHttpUrl, normalizeWsUrl } from "../../src/baseurl/normalize";

describe("normalizeWsUrl", () => {
  it("turns bare host:port into wss://…/ws (assume TLS)", () => {
    expect(normalizeWsUrl("example.test:39002")).toBe("wss://example.test:39002/ws");
  });
  it("keeps a full url verbatim (allows ws:// override), trimming trailing slash", () => {
    expect(normalizeWsUrl("ws://example.test:39002/ws/")).toBe("ws://example.test:39002/ws");
  });
  it("returns empty string for blank input", () => {
    expect(normalizeWsUrl("  ")).toBe("");
  });
});

describe("normalizeHttpUrl", () => {
  it("turns bare host:port into https:// (assume TLS), no path", () => {
    expect(normalizeHttpUrl("example.test:39001")).toBe("https://example.test:39001");
  });
  it("keeps a full url verbatim (allows http:// override), trimming trailing slash", () => {
    expect(normalizeHttpUrl("http://example.test:39003/")).toBe("http://example.test:39003");
  });
  it("returns empty string for blank input", () => {
    expect(normalizeHttpUrl("")).toBe("");
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm --filter @clawling/clawchat-plugin-install-core test tests/baseurl/normalize.test.ts`
Expected: FAIL — cannot find module `../../src/baseurl/normalize`.

- [ ] **Step 3: Write minimal implementation**

```typescript
// packages/core/src/baseurl/normalize.ts
const HAS_SCHEME = /^[a-z][a-z0-9+.-]*:\/\//i;

function trimTrailingSlash(value: string): string {
  return value.replace(/\/+$/, "");
}

/** Bare `host:port` → `wss://host:port/ws`; a schemed URL is kept verbatim. */
export function normalizeWsUrl(input: string): string {
  const value = input.trim();
  if (!value) {
    return "";
  }
  if (HAS_SCHEME.test(value)) {
    return trimTrailingSlash(value);
  }
  return `wss://${trimTrailingSlash(value)}/ws`;
}

/** Bare `host:port` → `https://host:port`; a schemed URL is kept verbatim. */
export function normalizeHttpUrl(input: string): string {
  const value = input.trim();
  if (!value) {
    return "";
  }
  if (HAS_SCHEME.test(value)) {
    return trimTrailingSlash(value);
  }
  return `https://${trimTrailingSlash(value)}`;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm --filter @clawling/clawchat-plugin-install-core test tests/baseurl/normalize.test.ts`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/core/src/baseurl/normalize.ts packages/core/tests/baseurl/normalize.test.ts
git commit -m "feat(core): add base-url normalization helpers"
```

---

### Task 2: Target parsing + hermes yaml URL (`target.ts`)

**Files:**
- Create: `packages/core/src/baseurl/target.ts`
- Test: `packages/core/tests/baseurl/target.test.ts`

- [ ] **Step 1: Write the failing test**

```typescript
// packages/core/tests/baseurl/target.test.ts
import { describe, expect, it } from "vitest";
import { hermesRawYamlUrl, parseTarget } from "../../src/baseurl/target";

describe("parseTarget", () => {
  it("parses a bare host", () => {
    expect(parseTarget("openclaw")).toEqual({ host: "openclaw" });
  });
  it("splits host@ref on the first @ (ref may contain @ later)", () => {
    expect(parseTarget("openclaw@dev")).toEqual({ host: "openclaw", ref: "dev" });
    expect(parseTarget("hermes@https://github.com/o/r.git#dev")).toEqual({
      host: "hermes",
      ref: "https://github.com/o/r.git#dev",
    });
  });
  it("rejects an unknown host", () => {
    expect(() => parseTarget("bogus")).toThrow(/openclaw, hermes/);
  });
  it("rejects a non-string", () => {
    expect(() => parseTarget(undefined)).toThrow(/--target/);
  });
});

describe("hermesRawYamlUrl", () => {
  it("derives a raw url from a full git url with branch", () => {
    expect(hermesRawYamlUrl("https://github.com/clawling/clawchat-plugin-hermes-agent.git#dev")).toBe(
      "https://raw.githubusercontent.com/clawling/clawchat-plugin-hermes-agent/dev/plugin.yaml",
    );
  });
  it("defaults to main when no branch is given", () => {
    expect(hermesRawYamlUrl("clawling/clawchat-plugin-hermes-agent")).toBe(
      "https://raw.githubusercontent.com/clawling/clawchat-plugin-hermes-agent/main/plugin.yaml",
    );
  });
  it("returns null for an unparseable ref", () => {
    expect(hermesRawYamlUrl("git@example.com:weird")).toBeNull();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm --filter @clawling/clawchat-plugin-install-core test tests/baseurl/target.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Write minimal implementation**

```typescript
// packages/core/src/baseurl/target.ts
import { isClawchatTarget, type ClawchatTarget } from "../config";
import { ClawchatError } from "../errors";

export interface ParsedTarget {
  host: ClawchatTarget;
  ref?: string;
}

/** Split `host[@ref]` on the FIRST `@` (host never contains `@`). */
export function parseTarget(value: unknown): ParsedTarget {
  if (typeof value !== "string" || !value.trim()) {
    throw new ClawchatError("VALIDATION", "--target is required (openclaw or hermes)");
  }
  const at = value.indexOf("@");
  const host = at === -1 ? value : value.slice(0, at);
  const ref = at === -1 ? "" : value.slice(at + 1).trim();
  if (!isClawchatTarget(host)) {
    throw new ClawchatError("VALIDATION", "--target must be one of: openclaw, hermes");
  }
  return ref ? { host, ref } : { host };
}

/**
 * Derive the raw `plugin.yaml` URL for a Hermes git ref so the compat pre-check
 * reads the branch being installed. Returns null when the ref can't be parsed.
 * Accepts `owner/repo[#branch]` and `https://github.com/owner/repo[.git][#branch]`.
 */
export function hermesRawYamlUrl(ref: string): string | null {
  let spec = ref.trim();
  let branch = "main";
  const hash = spec.indexOf("#");
  if (hash !== -1) {
    branch = spec.slice(hash + 1).trim() || "main";
    spec = spec.slice(0, hash);
  }
  spec = spec.replace(/\.git$/, "");
  const match =
    spec.match(/github\.com[/:]([^/]+)\/([^/]+)$/i) ?? spec.match(/^([^/@:\s]+)\/([^/@:\s]+)$/);
  if (!match) {
    return null;
  }
  return `https://raw.githubusercontent.com/${match[1]}/${match[2]}/${branch}/plugin.yaml`;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm --filter @clawling/clawchat-plugin-install-core test tests/baseurl/target.test.ts`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/core/src/baseurl/target.ts packages/core/tests/baseurl/target.test.ts
git commit -m "feat(core): parse @-suffixed targets and hermes branch yaml url"
```

---

### Task 3: OpenClaw config writer (`write-openclaw.ts`)

**Files:**
- Create: `packages/core/src/baseurl/write-openclaw.ts`
- Test: `packages/core/tests/baseurl/write-openclaw.test.ts`

- [ ] **Step 1: Write the failing test**

```typescript
// packages/core/tests/baseurl/write-openclaw.test.ts
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { writeOpenClawBaseUrls } from "../../src/baseurl/write-openclaw";

let home: string;

beforeEach(() => {
  home = fs.mkdtempSync(path.join(os.tmpdir(), "openclaw-home-"));
});
afterEach(() => {
  fs.rmSync(home, { recursive: true, force: true });
});

function readConfig() {
  return JSON.parse(fs.readFileSync(path.join(home, ".openclaw", "openclaw.json"), "utf8"));
}

describe("writeOpenClawBaseUrls", () => {
  it("creates the config file and channel when absent", () => {
    writeOpenClawBaseUrls(
      { baseUrl: "https://api.test:39001", websocketUrl: "wss://ws.test:39002/ws", mediaBaseUrl: "https://m.test:39003" },
      { homeDir: home },
    );
    expect(readConfig().channels["clawchat-plugin-openclaw"]).toEqual({
      baseUrl: "https://api.test:39001",
      websocketUrl: "wss://ws.test:39002/ws",
      mediaBaseUrl: "https://m.test:39003",
    });
  });

  it("merges into existing config, preserving other keys", () => {
    const dir = path.join(home, ".openclaw");
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(
      path.join(dir, "openclaw.json"),
      JSON.stringify({ channels: { "clawchat-plugin-openclaw": { token: "keep" } }, other: 1 }),
    );
    writeOpenClawBaseUrls({ baseUrl: "https://api.test:39001" }, { homeDir: home });
    const cfg = readConfig();
    expect(cfg.other).toBe(1);
    expect(cfg.channels["clawchat-plugin-openclaw"]).toEqual({ token: "keep", baseUrl: "https://api.test:39001" });
  });

  it("is a no-op when no values are provided (does not touch fs)", () => {
    writeOpenClawBaseUrls({}, { homeDir: home });
    expect(fs.existsSync(path.join(home, ".openclaw", "openclaw.json"))).toBe(false);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm --filter @clawling/clawchat-plugin-install-core test tests/baseurl/write-openclaw.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Write minimal implementation**

```typescript
// packages/core/src/baseurl/write-openclaw.ts
import * as fs from "node:fs";
import * as path from "node:path";
import { getOpenClawConfigPath } from "../auth/openclaw";
import { OPENCLAW_CHANNEL } from "../config";

export interface OpenClawBaseUrls {
  baseUrl?: string;
  websocketUrl?: string;
  mediaBaseUrl?: string;
}

export interface WriteOpenClawOptions {
  homeDir?: string;
}

/** Idempotently upsert base-URL keys into the openclaw.json clawchat channel. */
export function writeOpenClawBaseUrls(values: OpenClawBaseUrls, options: WriteOpenClawOptions = {}): void {
  const entries = Object.entries(values).filter(([, value]) => typeof value === "string" && value.trim());
  if (entries.length === 0) {
    return;
  }
  const configPath = getOpenClawConfigPath({ homeDir: options.homeDir });
  let config: Record<string, any> = {};
  try {
    const parsed = JSON.parse(fs.readFileSync(configPath, "utf8"));
    if (parsed && typeof parsed === "object") {
      config = parsed;
    }
  } catch {
    config = {};
  }
  if (!config.channels || typeof config.channels !== "object") {
    config.channels = {};
  }
  if (!config.channels[OPENCLAW_CHANNEL] || typeof config.channels[OPENCLAW_CHANNEL] !== "object") {
    config.channels[OPENCLAW_CHANNEL] = {};
  }
  for (const [key, value] of entries) {
    config.channels[OPENCLAW_CHANNEL][key] = value;
  }
  fs.mkdirSync(path.dirname(configPath), { recursive: true });
  fs.writeFileSync(configPath, `${JSON.stringify(config, null, 2)}\n`, "utf8");
}
```

Note: `getOpenClawConfigPath` from `auth/openclaw.ts` accepts `{ homeDir }` and returns `<home>/.openclaw/openclaw.json` — reuse it (DRY). `OPENCLAW_CHANNEL` is already exported from `config.ts`.

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm --filter @clawling/clawchat-plugin-install-core test tests/baseurl/write-openclaw.test.ts`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/core/src/baseurl/write-openclaw.ts packages/core/tests/baseurl/write-openclaw.test.ts
git commit -m "feat(core): upsert base urls into openclaw.json channel"
```

---

### Task 4: Hermes `.env` writer (`write-hermes.ts`)

**Files:**
- Create: `packages/core/src/baseurl/write-hermes.ts`
- Test: `packages/core/tests/baseurl/write-hermes.test.ts`

- [ ] **Step 1: Write the failing test**

```typescript
// packages/core/tests/baseurl/write-hermes.test.ts
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { getHermesEnvPath, writeHermesBaseUrls } from "../../src/baseurl/write-hermes";

let home: string;

beforeEach(() => {
  home = fs.mkdtempSync(path.join(os.tmpdir(), "hermes-home-"));
});
afterEach(() => {
  fs.rmSync(home, { recursive: true, force: true });
});

function readEnv() {
  return fs.readFileSync(getHermesEnvPath({ homeDir: home, env: {} }), "utf8");
}

describe("writeHermesBaseUrls", () => {
  it("creates ~/.hermes/.env with KEY=value lines", () => {
    writeHermesBaseUrls(
      { CLAWCHAT_BASE_URL: "https://api.test:39001", CLAWCHAT_MEDIA_BASE_URL: "https://m.test:39003" },
      { homeDir: home, env: {} },
    );
    const text = readEnv();
    expect(text).toContain("CLAWCHAT_BASE_URL=https://api.test:39001\n");
    expect(text).toContain("CLAWCHAT_MEDIA_BASE_URL=https://m.test:39003\n");
  });

  it("replaces an existing key and preserves unrelated lines (e.g. token)", () => {
    const dir = path.join(home, ".hermes");
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, ".env"), "CLAWCHAT_TOKEN=keep\nCLAWCHAT_BASE_URL=https://old\n");
    writeHermesBaseUrls({ CLAWCHAT_BASE_URL: "https://new" }, { homeDir: home, env: {} });
    const text = readEnv();
    expect(text).toContain("CLAWCHAT_TOKEN=keep\n");
    expect(text).toContain("CLAWCHAT_BASE_URL=https://new\n");
    expect(text).not.toContain("https://old");
  });

  it("prefers HERMES_HOME/.env when set", () => {
    const hermesHome = path.join(home, "custom-hermes");
    writeHermesBaseUrls({ CLAWCHAT_BASE_URL: "https://api.test" }, { env: { HERMES_HOME: hermesHome } });
    expect(fs.readFileSync(path.join(hermesHome, ".env"), "utf8")).toContain("CLAWCHAT_BASE_URL=https://api.test\n");
  });

  it("is a no-op when no values are provided", () => {
    writeHermesBaseUrls({}, { homeDir: home, env: {} });
    expect(fs.existsSync(getHermesEnvPath({ homeDir: home, env: {} }))).toBe(false);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm --filter @clawling/clawchat-plugin-install-core test tests/baseurl/write-hermes.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Write minimal implementation**

```typescript
// packages/core/src/baseurl/write-hermes.ts
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

export interface HermesBaseUrls {
  CLAWCHAT_BASE_URL?: string;
  CLAWCHAT_WEBSOCKET_URL?: string;
  CLAWCHAT_MEDIA_BASE_URL?: string;
}

export interface WriteHermesOptions {
  homeDir?: string;
  env?: Record<string, string | undefined>;
}

/** Mirrors the plugin's reader: `$HERMES_HOME/.env` if set, else `~/.hermes/.env`. */
export function getHermesEnvPath(options: WriteHermesOptions = {}): string {
  const env = options.env ?? process.env;
  if (env.HERMES_HOME?.trim()) {
    return path.join(env.HERMES_HOME, ".env");
  }
  return path.join(options.homeDir ?? os.homedir(), ".hermes", ".env");
}

/** Idempotently upsert `KEY=value` lines (format the plugin's reader parses). */
export function writeHermesBaseUrls(values: HermesBaseUrls, options: WriteHermesOptions = {}): void {
  const entries = Object.entries(values).filter(([, value]) => typeof value === "string" && value.trim()) as [
    string,
    string,
  ][];
  if (entries.length === 0) {
    return;
  }
  const envPath = getHermesEnvPath(options);
  let existing = "";
  try {
    existing = fs.readFileSync(envPath, "utf8");
  } catch {
    existing = "";
  }
  const lines = existing.length ? existing.split(/\r?\n/) : [];
  for (const [key, value] of entries) {
    const index = lines.findIndex((line) => line.trim().replace(/^export\s+/, "").startsWith(`${key}=`));
    const next = `${key}=${value}`;
    if (index === -1) {
      lines.push(next);
    } else {
      lines[index] = next;
    }
  }
  const out = `${lines.join("\n").replace(/\n+$/, "")}\n`;
  fs.mkdirSync(path.dirname(envPath), { recursive: true });
  fs.writeFileSync(envPath, out, "utf8");
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm --filter @clawling/clawchat-plugin-install-core test tests/baseurl/write-hermes.test.ts`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/core/src/baseurl/write-hermes.ts packages/core/tests/baseurl/write-hermes.test.ts
git commit -m "feat(core): upsert clawchat base urls into hermes .env"
```

---

### Task 5: Shared `InstallerOptions` + exports

**Files:**
- Modify: `packages/core/src/installers/types.ts`
- Modify: `packages/core/src/index.ts`

- [ ] **Step 1: Extend `types.ts`** — replace the file contents with:

```typescript
// packages/core/src/installers/types.ts
import type { CommandCapturer, CommandRunner } from "./run";

export type InstallActionStatus = "installed" | "updated" | "skipped";
export type InstallProgressReporter = (message: string) => void;

export interface InstallActionResult {
  kind: "plugin";
  target: "openclaw" | "hermes";
  status: InstallActionStatus;
  version?: string;
  previousVersion?: string | null;
  path?: string;
  detail?: string;
}

/** Normalized full-URL overrides (already scheme-prefixed by the CLI). */
export interface BaseUrlOverrides {
  apiBaseUrl?: string;
  wsBaseUrl?: string;
  mediaBaseUrl?: string;
}

/** Persists base URLs to the host before install; injectable for tests. */
export type BaseUrlWriter = (values: BaseUrlOverrides) => void;

export interface InstallerOptions {
  run?: CommandRunner;
  capture?: CommandCapturer;
  force?: boolean;
  onProgress?: InstallProgressReporter;
  /** `@<ref>` from the target: npm version/dist-tag (openclaw) or git url#branch (hermes). */
  ref?: string;
  apiBaseUrl?: string;
  wsBaseUrl?: string;
  mediaBaseUrl?: string;
  writeBaseUrls?: BaseUrlWriter;
}
```

- [ ] **Step 2: Export new modules from `index.ts`** — append:

```typescript
export * from "./baseurl/normalize";
export * from "./baseurl/target";
export * from "./baseurl/write-hermes";
export * from "./baseurl/write-openclaw";
```

- [ ] **Step 3: Typecheck**

Run: `pnpm typecheck`
Expected: PASS — both installers still compile (they import `InstallerOptions`-shaped local interfaces; Task 6/7 switch them to the shared type).

> Note: `openclaw.ts` and `hermes.ts` each currently declare a local `InstallerOptions`. That's fine until Tasks 6–7 replace them. Typecheck passes because nothing yet consumes the new fields.

- [ ] **Step 4: Commit**

```bash
git add packages/core/src/installers/types.ts packages/core/src/index.ts
git commit -m "feat(core): shared InstallerOptions with ref + base-url overrides"
```

---

### Task 6: OpenClaw installer — ref spec + pre-install write

**Files:**
- Modify: `packages/core/src/installers/openclaw.ts`
- Test: `packages/core/tests/installers/openclaw.test.ts` (extend)

- [ ] **Step 1: Write the failing tests** — append inside the existing `describe("OpenClaw installer", …)` block in `packages/core/tests/installers/openclaw.test.ts`:

```typescript
  it("appends the @ref to the npm spec", async () => {
    const run = vi.fn(async () => undefined);
    const capture = mockHostWorkspaceCapture();
    const writeBaseUrls = vi.fn();

    await installOpenClawPlugin({ run, capture, ref: "dev", writeBaseUrls });

    expect(run.mock.calls).toEqual([
      ["openclaw", ["plugins", "install", "@clawling/clawchat-plugin-openclaw@dev"]],
    ]);
  });

  it("writes base urls before installing", async () => {
    const order: string[] = [];
    const run = vi.fn(async () => {
      order.push("run");
    });
    const capture = mockHostWorkspaceCapture();
    const writeBaseUrls = vi.fn(() => {
      order.push("write");
    });

    await installOpenClawPlugin({
      run,
      capture,
      writeBaseUrls,
      apiBaseUrl: "https://api.test:39001",
      wsBaseUrl: "wss://ws.test:39002/ws",
      mediaBaseUrl: "https://m.test:39003",
    });

    expect(writeBaseUrls).toHaveBeenCalledWith({
      apiBaseUrl: "https://api.test:39001",
      wsBaseUrl: "wss://ws.test:39002/ws",
      mediaBaseUrl: "https://m.test:39003",
    });
    expect(order[0]).toBe("write");
    expect(order).toContain("run");
  });
```

- [ ] **Step 2: Run to verify failure**

Run: `pnpm --filter @clawling/clawchat-plugin-install-core test tests/installers/openclaw.test.ts`
Expected: FAIL — `ref`/`writeBaseUrls` not yet handled (spec lacks `@dev`; writeBaseUrls never called).

- [ ] **Step 3: Implement** — edit `packages/core/src/installers/openclaw.ts`:

Replace the imports + local interface at the top:

```typescript
import { OPENCLAW_PLUGIN_SPEC } from "../config";
import { writeOpenClawBaseUrls } from "../baseurl/write-openclaw";
import { captureCommand, runCommand, type CommandCapturer, type CommandRunner } from "./run";
import type { BaseUrlWriter, InstallActionResult, InstallProgressReporter, InstallerOptions } from "./types";

const defaultOpenClawBaseUrlWriter: BaseUrlWriter = (values) =>
  writeOpenClawBaseUrls({
    baseUrl: values.apiBaseUrl,
    websocketUrl: values.wsBaseUrl,
    mediaBaseUrl: values.mediaBaseUrl,
  });

function openClawSpec(ref?: string): string {
  return ref ? `${OPENCLAW_PLUGIN_SPEC}@${ref}` : OPENCLAW_PLUGIN_SPEC;
}

function persistOpenClawBaseUrls(options: InstallerOptions): void {
  const write = options.writeBaseUrls ?? defaultOpenClawBaseUrlWriter;
  write({
    ...(options.apiBaseUrl ? { apiBaseUrl: options.apiBaseUrl } : {}),
    ...(options.wsBaseUrl ? { wsBaseUrl: options.wsBaseUrl } : {}),
    ...(options.mediaBaseUrl ? { mediaBaseUrl: options.mediaBaseUrl } : {}),
  });
}
```

Delete the old local `interface InstallerOptions { … }` block (now imported).

In `installOpenClawPlugin`, after `const progress = options.onProgress;` add `persistOpenClawBaseUrls(options);` then change the spec lines:

```typescript
  persistOpenClawBaseUrls(options);
  progress?.(force ? "Reinstalling OpenClaw plugin..." : "Installing OpenClaw plugin...");
  await repairStaleOpenClawWorkspace(run, capture);
  const spec = openClawSpec(options.ref);
  const args = force ? ["plugins", "install", spec, "--force"] : ["plugins", "install", spec];
  await run("openclaw", args);
```

In `updateOpenClawPlugin`, after `const progress = options.onProgress;` add `persistOpenClawBaseUrls(options);` and change the args:

```typescript
  persistOpenClawBaseUrls(options);
  progress?.(force ? "Reinstalling OpenClaw plugin..." : "Updating OpenClaw plugin...");
  await repairStaleOpenClawWorkspace(run, capture);
  const spec = openClawSpec(options.ref);
  const args = force ? ["plugins", "install", spec, "--force"] : ["plugins", "update", spec];
  await run("openclaw", args);
```

> The empty-spread for `persistOpenClawBaseUrls` means the existing tests (no URLs) call the default writer with `{}`, which `writeOpenClawBaseUrls` treats as a no-op — no fs writes, existing assertions unaffected.

- [ ] **Step 4: Run to verify pass**

Run: `pnpm --filter @clawling/clawchat-plugin-install-core test tests/installers/openclaw.test.ts`
Expected: PASS — all existing + 2 new tests green.

- [ ] **Step 5: Commit**

```bash
git add packages/core/src/installers/openclaw.ts packages/core/tests/installers/openclaw.test.ts
git commit -m "feat(core): openclaw installer honors @ref and writes base urls"
```

---

### Task 7: Hermes installer — ref-forced install + branch yaml + write

**Files:**
- Modify: `packages/core/src/installers/hermes.ts`
- Test: `packages/core/tests/installers/hermes.test.ts` (extend; create if absent)

- [ ] **Step 1: Write the failing tests** — add to `packages/core/tests/installers/hermes.test.ts`:

```typescript
import { describe, expect, it, vi } from "vitest";
import { installHermesPlugin } from "../../src/installers/hermes";

const YAML = "version: 0.14.0-22\nrequires:\n  hermes: \">=0.12.0\"\n";

describe("Hermes installer with @ref", () => {
  it("force-installs the git ref and fetches branch plugin.yaml", async () => {
    const run = vi.fn(async () => undefined);
    const capture = vi.fn(async (cmd: string, args: readonly string[]) => {
      if (cmd === "curl") {
        expect(args[1]).toBe(
          "https://raw.githubusercontent.com/clawling/clawchat-plugin-hermes-agent/dev/plugin.yaml",
        );
        return YAML;
      }
      if (cmd === "hermes" && args[0] === "--version") return "hermes 0.12.0\n";
      throw new Error(`unexpected capture: ${cmd} ${args.join(" ")}`);
    });
    const writeBaseUrls = vi.fn();

    const result = await installHermesPlugin({
      run,
      capture,
      writeBaseUrls,
      ref: "https://github.com/clawling/clawchat-plugin-hermes-agent.git#dev",
    });

    expect(result).toMatchObject({ kind: "plugin", target: "hermes", status: "installed" });
    expect(run.mock.calls).toEqual([
      [
        "hermes",
        ["plugins", "install", "https://github.com/clawling/clawchat-plugin-hermes-agent.git#dev", "--force", "--enable"],
      ],
    ]);
  });

  it("still force-installs when branch plugin.yaml is unavailable", async () => {
    const run = vi.fn(async () => undefined);
    const capture = vi.fn(async (cmd: string, args: readonly string[]) => {
      if (cmd === "curl") throw new Error("curl: (22) 404");
      throw new Error(`unexpected capture: ${cmd} ${args.join(" ")}`);
    });

    const result = await installHermesPlugin({
      run,
      capture,
      writeBaseUrls: vi.fn(),
      ref: "https://github.com/clawling/clawchat-plugin-hermes-agent.git#dev",
    });

    expect(result.status).toBe("installed");
    expect(run.mock.calls[0]![1]).toContain("--force");
  });
});
```

- [ ] **Step 2: Run to verify failure**

Run: `pnpm --filter @clawling/clawchat-plugin-install-core test tests/installers/hermes.test.ts`
Expected: FAIL — ref path not implemented (curl hits the hardcoded main URL / writeBaseUrls unused).

- [ ] **Step 3: Implement** — edit `packages/core/src/installers/hermes.ts`:

Update the top imports:

```typescript
import { HERMES_PLUGIN_NAME, HERMES_PLUGIN_SPEC, HERMES_PLUGIN_YAML_URL } from "../config";
import { writeHermesBaseUrls } from "../baseurl/write-hermes";
import { hermesRawYamlUrl } from "../baseurl/target";
import { ClawchatError } from "../errors";
import {
  assertVersionSatisfiesRange,
  type HermesInstalledPlugin,
  isVersionOlder,
  parseHermesPluginList,
  parseHermesPluginYaml,
  parseHostVersion,
  type PluginArtifactMetadata,
} from "./metadata";
import { captureCommand, runCommand, type CommandRunner } from "./run";
import type { BaseUrlWriter, InstallActionResult, InstallProgressReporter, InstallerOptions } from "./types";

const defaultHermesBaseUrlWriter: BaseUrlWriter = (values) =>
  writeHermesBaseUrls({
    CLAWCHAT_BASE_URL: values.apiBaseUrl,
    CLAWCHAT_WEBSOCKET_URL: values.wsBaseUrl,
    CLAWCHAT_MEDIA_BASE_URL: values.mediaBaseUrl,
  });

function persistHermesBaseUrls(options: InstallerOptions): void {
  const write = options.writeBaseUrls ?? defaultHermesBaseUrlWriter;
  write({
    ...(options.apiBaseUrl ? { apiBaseUrl: options.apiBaseUrl } : {}),
    ...(options.wsBaseUrl ? { wsBaseUrl: options.wsBaseUrl } : {}),
    ...(options.mediaBaseUrl ? { mediaBaseUrl: options.mediaBaseUrl } : {}),
  });
}
```

Delete the old local `interface InstallerOptions { … }` block.

Add a ref-install helper (place after `readHermesInstallerContext`):

```typescript
async function installHermesFromRef(options: InstallerOptions): Promise<InstallActionResult> {
  const run = options.run ?? runCommand;
  const capture = options.capture ?? captureCommand;
  const progress = options.onProgress;
  const spec = options.ref as string;

  let version = spec;
  const yamlUrl = hermesRawYamlUrl(spec);
  if (yamlUrl) {
    let artifact: PluginArtifactMetadata | undefined;
    try {
      artifact = parseHermesPluginYaml(await capture("curl", ["-fsL", yamlUrl]));
    } catch {
      progress?.(`branch plugin.yaml unavailable for ${spec}; skipping version check`);
    }
    if (artifact) {
      version = artifact.version;
      const hostVersion = parseHostVersion(await capture("hermes", ["--version"]));
      assertVersionSatisfiesRange(hostVersion, artifact.hostRequirement, "Hermes");
    }
  }

  progress?.(`plugin installing ${spec}`);
  await run("hermes", ["plugins", "install", spec, "--force", "--enable"]);
  return { kind: "plugin", target: "hermes", status: "installed", version, previousVersion: null };
}
```

At the very start of `installHermesPlugin`, before the existing `const { run, … } = await readHermesInstallerContext(options);`, insert:

```typescript
  persistHermesBaseUrls(options);
  if (options.ref) {
    return installHermesFromRef(options);
  }
```

At the very start of `updateHermesPlugin`, insert the same two-line block (`persistHermesBaseUrls(options); if (options.ref) { return installHermesFromRef(options); }`).

> `--target hermes@<ref>` means "install exactly this ref" — always a forced install, sidestepping the semver compare path (a branch yaml version like `0.14.0-22` parses fine, but the operator's intent is explicit). The `parseHostVersion`/`assertVersionSatisfiesRange` calls live OUTSIDE the swallowing try, so a real "host too old" PRECONDITION still propagates while a 404 on the branch yaml is tolerated.

- [ ] **Step 4: Run to verify pass + full core suite**

Run: `pnpm --filter @clawling/clawchat-plugin-install-core test`
Expected: PASS — new hermes ref tests + all existing core tests green.

- [ ] **Step 5: Commit**

```bash
git add packages/core/src/installers/hermes.ts packages/core/tests/installers/hermes.test.ts
git commit -m "feat(core): hermes installer force-installs @ref branch + writes base urls"
```

---

### Task 8: CLI flags + thread options

**Files:**
- Modify: `packages/cli/src/cli.ts`
- Test: `packages/cli/tests/cli.test.ts` (extend)

- [ ] **Step 1: Write the failing tests** — append to the `describe("runClawchatCli install/update", …)` block:

```typescript
  it("normalizes base-url flags and threads ref to the openclaw installer", async () => {
    const io = createIo();
    const installOpenClawPlugin = vi.fn(async () => ({
      kind: "plugin" as const,
      target: "openclaw" as const,
      status: "installed" as const,
      version: "0.1.3",
      previousVersion: null,
    }));

    const code = await runClawchatCli(
      [
        "install",
        "--target",
        "openclaw@dev",
        "--apibaseurl",
        "example.test:39001",
        "--wsbaseurl",
        "example.test:39002",
        "--mediabaseurl",
        "example.test:39003",
      ],
      { ...io.io, installOpenClawPlugin },
    );

    expect(code).toBe(0);
    expect(installOpenClawPlugin).toHaveBeenCalledWith(
      expect.objectContaining({
        ref: "dev",
        apiBaseUrl: "https://example.test:39001",
        wsBaseUrl: "wss://example.test:39002/ws",
        mediaBaseUrl: "https://example.test:39003",
      }),
    );
  });
```

- [ ] **Step 2: Run to verify failure**

Run: `pnpm --filter @clawling/clawchat-plugin-install-cli test tests/cli.test.ts`
Expected: FAIL — options not threaded; `installOpenClawPlugin` called without `ref`/URLs.

- [ ] **Step 3: Implement** — edit `packages/cli/src/cli.ts`:

Update the import from core (drop `isClawchatTarget`, add helpers):

```typescript
import {
  installHermesPlugin,
  installOpenClawPlugin,
  normalizeHttpUrl,
  normalizeWsUrl,
  parseTarget,
  updateHermesPlugin,
  updateOpenClawPlugin,
  type ClawchatTarget,
  type InstallActionResult,
  type InstallProgressReporter,
} from "@clawling/clawchat-plugin-install-core";
```

Replace the `PluginAction` type and delete the local `parseTarget` function:

```typescript
type PluginAction = (options?: {
  force?: boolean;
  onProgress?: InstallProgressReporter;
  ref?: string;
  apiBaseUrl?: string;
  wsBaseUrl?: string;
  mediaBaseUrl?: string;
}) => Promise<InstallActionResult>;
```

Add a helper to build action options (place above `runClawchatCli`):

```typescript
interface BaseUrlFlags {
  apibaseurl?: string;
  wsbaseurl?: string;
  mediabaseurl?: string;
}

function buildBaseUrlOptions(ref: string | undefined, flags: BaseUrlFlags) {
  const apiBaseUrl = flags.apibaseurl ? normalizeHttpUrl(flags.apibaseurl) : undefined;
  const wsBaseUrl = flags.wsbaseurl ? normalizeWsUrl(flags.wsbaseurl) : undefined;
  const mediaBaseUrl = flags.mediabaseurl ? normalizeHttpUrl(flags.mediabaseurl) : undefined;
  return {
    ...(ref ? { ref } : {}),
    ...(apiBaseUrl ? { apiBaseUrl } : {}),
    ...(wsBaseUrl ? { wsBaseUrl } : {}),
    ...(mediaBaseUrl ? { mediaBaseUrl } : {}),
  };
}
```

For BOTH the `install` and `update` command builders, add the three options and rewrite the action. Install command:

```typescript
  cli
    .command("install", "Install ClawChat plugin")
    .option("--target <target>", "Target agent: openclaw or hermes (optionally host@ref)")
    .option("--force", "Reinstall ClawChat plugin even when current")
    .option("--apibaseurl <url>", "REST/API base url (host:port or full url)")
    .option("--wsbaseurl <url>", "WebSocket base url (host:port or full url)")
    .option("--mediabaseurl <url>", "Media base url (host:port or full url)")
    .action(
      async (options: {
        target?: string;
        force?: boolean;
        apibaseurl?: string;
        wsbaseurl?: string;
        mediabaseurl?: string;
      }) => {
        commandRan = true;
        const { host, ref } = parseTarget(options.target);
        const onProgress = createProgressReporter(io);
        const actionOptions = {
          force: options.force === true,
          onProgress,
          ...buildBaseUrlOptions(ref, options),
        };
        const pluginResult = await pluginActions.install[host](actionOptions);
        io.writeStdout(formatSummary("install", host, pluginResult));
      },
    );
```

Apply the identical change to the `update` command (same three `.option(...)` lines; `pluginActions.update[host]`; `formatSummary("update", host, …)`).

> `parseTarget` now returns `{ host, ref }`; `host` is the `ClawchatTarget` used to index `pluginActions`.

- [ ] **Step 4: Run to verify pass + full cli suite + typecheck**

Run: `pnpm --filter @clawling/clawchat-plugin-install-cli test` then `pnpm typecheck`
Expected: PASS — new test + all existing cli tests green; types clean.

- [ ] **Step 5: Commit**

```bash
git add packages/cli/src/cli.ts packages/cli/tests/cli.test.ts
git commit -m "feat(cli): add --apibaseurl/--wsbaseurl/--mediabaseurl and @ref targets"
```

---

### Task 9: install-CLI README (placeholder hosts)

**Files:**
- Modify: the install-CLI README (`README.md` at the repo root; confirm path with `ls`).

- [ ] **Step 1: Add a "Custom backend + test branch" section** documenting the new flags with placeholder hosts only:

````markdown
### Pointing at a custom backend / installing a test branch

Pass the backend endpoints at install time (bare `host:port` is normalized to TLS;
pass a full `ws://`/`http://` URL to opt out of TLS). Use `host@ref` to install a
test branch/version:

```bash
# OpenClaw: install the `dev` dist-tag against a custom backend
npx -y @clawling/clawchat-plugin-install-cli@latest install \
  --target openclaw@dev \
  --apibaseurl <api-host:port> \
  --wsbaseurl <ws-host:port> \
  --mediabaseurl <media-host:port>

# Hermes: install a git branch against a custom backend
npx -y @clawling/clawchat-plugin-install-cli@latest install \
  --target hermes@https://github.com/clawling/clawchat-plugin-hermes-agent.git#dev \
  --apibaseurl <api-host:port> \
  --wsbaseurl <ws-host:port> \
  --mediabaseurl <media-host:port>
```

- `--apibaseurl` → REST/API base (activation, profile, friends, moments …)
- `--wsbaseurl` → WebSocket messaging (`/ws` is appended for bare host:port)
- `--mediabaseurl` → media upload/download

URLs are written before install — OpenClaw to `~/.openclaw/openclaw.json`, Hermes to
`~/.hermes/.env` — and the plugin reads them at startup, falling back to its defaults
when unset.
````

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs(cli): document base-url flags and @ref targets"
```

- [ ] **Step 3 (optional): bump aggregator pin** — per `clawchat-agent-plugin/CLAUDE.md`, from the aggregator root: `git add clawchat-plugin-install-cli && git commit -m "chore: bump install-cli submodule pin"`. (Do only when pushing.)

---

# Phase 2 — Hermes plugin (dedicated media base url)

All commands run from `clawchat-agent-plugin/clawchat-plugin-hermes-agent/`. Tests: `uv run pytest`.

### Task 10: `media_base_url` config field + resolution

**Files:**
- Modify: `clawchat_gateway/config.py`
- Test: `tests/test_media_base_url.py` (create)

- [ ] **Step 1: Write the failing test**

```python
# tests/test_media_base_url.py
from __future__ import annotations

from types import SimpleNamespace

from clawchat_gateway.config import ClawChatConfig


def _clear(monkeypatch):
    for name in ("CLAWCHAT_TOKEN", "CLAWCHAT_REFRESH_TOKEN", "CLAWCHAT_MEDIA_BASE_URL"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setattr("clawchat_gateway.config._read_hermes_env_value", lambda name: "")
    monkeypatch.setattr("clawchat_gateway.config._read_env_file_value", lambda name: "")


def test_media_base_url_from_env(monkeypatch):
    _clear(monkeypatch)
    monkeypatch.setenv("CLAWCHAT_MEDIA_BASE_URL", "https://media.test:39003")
    config = ClawChatConfig.from_platform_config(
        SimpleNamespace(extra={"websocket_url": "wss://ws.test/ws"})
    )
    assert config.media_base_url == "https://media.test:39003"


def test_media_base_url_from_extra(monkeypatch):
    _clear(monkeypatch)
    config = ClawChatConfig.from_platform_config(
        SimpleNamespace(extra={"websocket_url": "wss://ws.test/ws", "media_base_url": "https://m.extra"})
    )
    assert config.media_base_url == "https://m.extra"


def test_media_base_url_defaults_empty(monkeypatch):
    _clear(monkeypatch)
    config = ClawChatConfig.from_platform_config(
        SimpleNamespace(extra={"websocket_url": "wss://ws.test/ws"})
    )
    assert config.media_base_url == ""
```

- [ ] **Step 2: Run to verify failure**

Run: `uv run pytest tests/test_media_base_url.py -q`
Expected: FAIL — `ClawChatConfig` has no `media_base_url`.

- [ ] **Step 3: Implement** — in `clawchat_gateway/config.py`:

Add the field to the dataclass (right after `base_url: str = ""`):

```python
    base_url: str = ""
    media_base_url: str = ""
```

In `from_platform_config`, right after the `base_url=…` block (after the `or DEFAULT_BASE_URL,` line), add:

```python
            media_base_url=_get_env("CLAWCHAT_MEDIA_BASE_URL")
            or _get_config_value(extra, "media_base_url", ""),
```

- [ ] **Step 4: Run to verify pass**

Run: `uv run pytest tests/test_media_base_url.py -q`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add clawchat_gateway/config.py tests/test_media_base_url.py
git commit -m "feat: add media_base_url config slot to hermes clawchat"
```

---

### Task 11: `derive_base_url` honors explicit media base

**Files:**
- Modify: `clawchat_gateway/media_runtime.py`
- Test: `tests/test_media_base_url.py` (extend)

- [ ] **Step 1: Write the failing test** — append:

```python
from clawchat_gateway.media_runtime import derive_base_url


def test_derive_base_url_prefers_explicit_media_base():
    assert (
        derive_base_url(
            websocket_url="wss://ws.test/ws",
            base_url="https://api.test",
            media_base_url="https://media.test:39003/",
        )
        == "https://media.test:39003"
    )


def test_derive_base_url_falls_back_to_ws_derivation():
    assert (
        derive_base_url(websocket_url="wss://ws.test:39002/ws", base_url="", media_base_url="")
        == "https://ws.test:39002"
    )
```

- [ ] **Step 2: Run to verify failure**

Run: `uv run pytest tests/test_media_base_url.py -q`
Expected: FAIL — `derive_base_url` got an unexpected keyword `media_base_url`.

- [ ] **Step 3: Implement** — in `clawchat_gateway/media_runtime.py`:

Change `derive_base_url` (add the `media_base_url` keyword and short-circuit):

```python
def derive_base_url(*, websocket_url: str, base_url: str, media_base_url: str = "") -> str:
    if media_base_url.strip():
        return media_base_url.rstrip("/")
    parsed = urlparse(websocket_url)
    if parsed.scheme in {"ws", "wss"} and parsed.netloc:
        scheme = "https" if parsed.scheme == "wss" else "http"
        return urlunparse((scheme, parsed.netloc, "", "", "", "")).rstrip("/")

    if base_url.strip():
        return base_url.rstrip("/")

    if not parsed.scheme or not parsed.netloc:
        raise ValueError("base_url missing and websocket_url is not absolute")
    return base_url.rstrip("/")
```

Thread `media_base_url` through the three callers. `_resolve_inbound_media_url`:

```python
def _resolve_inbound_media_url(
    url: str,
    *,
    base_url: str,
    websocket_url: str,
    media_base_url: str = "",
) -> str:
    if _is_remote_url(url):
        return url
    resolved_base_url = derive_base_url(
        websocket_url=websocket_url, base_url=base_url, media_base_url=media_base_url
    )
    return urljoin(f"{resolved_base_url.rstrip('/')}/", url.lstrip("/"))
```

`upload_outbound_media` — add `media_base_url: str = "",` to its keyword params and update the derive call:

```python
async def upload_outbound_media(
    urls: list[str],
    *,
    base_url: str,
    websocket_url: str,
    token: str,
    media_local_roots: Sequence[str],
    upload_file=None,
    media_base_url: str = "",
) -> list[dict[str, object]]:
    if not urls:
        return []

    resolved_base_url = derive_base_url(
        websocket_url=websocket_url, base_url=base_url, media_base_url=media_base_url
    )
```

`download_inbound_media` — add `media_base_url: str = "",` to its keyword params and pass it into `_resolve_inbound_media_url`:

```python
async def download_inbound_media(
    urls: list[str],
    *,
    base_url: str,
    websocket_url: str,
    token: str,
    download_dir: str | Path,
    download_file=None,
    media_base_url: str = "",
) -> list[DownloadedMedia]:
    ...
            resolved_url = _resolve_inbound_media_url(
                url,
                base_url=base_url,
                websocket_url=websocket_url,
                media_base_url=media_base_url,
            )
```

- [ ] **Step 4: Run to verify pass + full suite**

Run: `uv run pytest tests/test_media_base_url.py -q` then `uv run pytest -q`
Expected: PASS — new tests + existing suite green (new param is optional, defaults preserve behavior).

- [ ] **Step 5: Commit**

```bash
git add clawchat_gateway/media_runtime.py tests/test_media_base_url.py
git commit -m "feat: media_runtime honors explicit media_base_url with derive fallback"
```

---

### Task 12: Adapter passes `media_base_url`

**Files:**
- Modify: `clawchat_gateway/adapter.py`

- [ ] **Step 1: Wire the config through both media call sites.** In `_download_inbound_media` (the `download_inbound_media(...)` call) add the kwarg:

```python
        downloaded = await download_inbound_media(
            inbound.media_urls,
            base_url=self._clawchat_config.base_url,
            websocket_url=self._clawchat_config.websocket_url,
            token=self._clawchat_config.token,
            download_dir=self._clawchat_config.media_download_dir,
            media_base_url=self._clawchat_config.media_base_url,
        )
```

In `_upload_outbound_media` (the `upload_outbound_media(...)` call) add the kwarg:

```python
        return await upload_outbound_media(
            media_urls,
            base_url=self._clawchat_config.base_url,
            websocket_url=self._clawchat_config.websocket_url,
            token=self._clawchat_config.token,
            media_local_roots=media_local_roots,
            media_base_url=self._clawchat_config.media_base_url,
        )
```

- [ ] **Step 2: Run the full suite**

Run: `uv run pytest -q`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add clawchat_gateway/adapter.py
git commit -m "feat: adapter forwards media_base_url to media transfer"
```

---

# Phase 3 — OpenClaw plugin (dedicated media base url)

All commands run from `clawchat-agent-plugin/clawchat-plugin-openclaw/`. Tests: `npm test` (vitest); single file: `npm test -- src/config.test.ts`.

### Task 13: Resolve `mediaBaseUrl` in config

**Files:**
- Modify: `src/config.ts`
- Test: `src/config.test.ts` (extend)

- [ ] **Step 1: Write the failing tests** — add to `src/config.test.ts`:

```typescript
  it("resolves mediaBaseUrl from the channel config", () => {
    const account = resolveOpenclawClawlingAccount({
      channels: { "clawchat-plugin-openclaw": { mediaBaseUrl: "https://media.cfg:39003" } },
    } as any);
    expect(account.mediaBaseUrl).toBe("https://media.cfg:39003");
  });

  it("resolves mediaBaseUrl from CLAWCHAT_MEDIA_BASE_URL when config omits it", () => {
    const account = resolveOpenclawClawlingAccount({}, { CLAWCHAT_MEDIA_BASE_URL: "https://media.env:39003" });
    expect(account.mediaBaseUrl).toBe("https://media.env:39003");
  });

  it("leaves mediaBaseUrl empty when unset (falls back to baseUrl downstream)", () => {
    const account = resolveOpenclawClawlingAccount({}, {});
    expect(account.mediaBaseUrl).toBe("");
  });
```

- [ ] **Step 2: Run to verify failure**

Run: `npm test -- src/config.test.ts`
Expected: FAIL — `account.mediaBaseUrl` is undefined.

- [ ] **Step 3: Implement** — in `src/config.ts`:

Add the env constant next to the others (after `CLAWCHAT_WEBSOCKET_URL_ENV`):

```typescript
export const CLAWCHAT_MEDIA_BASE_URL_ENV = "CLAWCHAT_MEDIA_BASE_URL" as const;
```

Add to the `OpenclawClawlingConfig` type (after `baseUrl?: string;`):

```typescript
  mediaBaseUrl?: string;
```

Add to the `ResolvedOpenclawClawlingAccount` type (after `baseUrl: string;`):

```typescript
  mediaBaseUrl: string;
```

Add to `openclawClawlingConfigSchema.properties` (after `baseUrl: { type: "string" },`):

```typescript
    mediaBaseUrl: { type: "string" },
```

In `resolveOpenclawClawlingAccount`, after the `baseUrl` const block, add:

```typescript
  const mediaBaseUrl =
    readOptionalString(channel.mediaBaseUrl) || readEnvString(env, CLAWCHAT_MEDIA_BASE_URL_ENV);
```

And add `mediaBaseUrl,` to the returned object (after `baseUrl,`).

- [ ] **Step 4: Run to verify pass**

Run: `npm test -- src/config.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/config.ts src/config.test.ts
git commit -m "feat: resolve mediaBaseUrl in openclaw clawchat config"
```

---

### Task 14: Media upload uses `mediaBaseUrl`

**Files:**
- Modify: `src/api-client.ts`
- Test: `src/api-client.test.ts` (extend)

- [ ] **Step 1: Write the failing test** — add to `src/api-client.test.ts`:

```typescript
  it("uploadMedia targets mediaBaseUrl when provided, leaving /v1 on baseUrl", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(
      jsonResponse({
        code: 0,
        message: "ok",
        data: { kind: "image", url: "https://cdn/x.png", name: "x.png", size: 12, mime: "image/png" },
      }),
    );
    const client = createOpenclawClawlingApiClient({
      baseUrl: "https://api.example.com",
      mediaBaseUrl: "https://media.example.com:39003",
      token: "tk",
      fetchImpl,
    });
    await client.uploadMedia({ buffer: Buffer.from("hi-bytes-12!"), filename: "x.png", mime: "image/png" });
    expect(fetchImpl.mock.calls[0]![0]).toBe("https://media.example.com:39003/media/upload");
  });
```

- [ ] **Step 2: Run to verify failure**

Run: `npm test -- src/api-client.test.ts`
Expected: FAIL — upload still hits `https://api.example.com/media/upload`.

- [ ] **Step 3: Implement** — in `src/api-client.ts`:

Add `mediaBaseUrl` to `ApiClientOptions` (after `userId?: string;`):

```typescript
  /** Optional dedicated base for `/media/upload`; defaults to `baseUrl`. */
  mediaBaseUrl?: string;
```

Inside `createOpenclawClawlingApiClient`, after `const baseUrl = opts.baseUrl.replace(/\/+$/, "");`, add:

```typescript
  let mediaBaseUrl = baseUrl;
  if (opts.mediaBaseUrl && opts.mediaBaseUrl.trim()) {
    if (!/^https?:\/\//i.test(opts.mediaBaseUrl)) {
      throw new ClawlingApiError(
        "validation",
        `clawchat-plugin-openclaw mediaBaseUrl must start with http:// or https:// (got "${opts.mediaBaseUrl}")`,
      );
    }
    mediaBaseUrl = opts.mediaBaseUrl.replace(/\/+$/, "");
  }
```

Change the `url` helper to accept a base override:

```typescript
  function url(path: string, base: string = baseUrl): string {
    return `${base}${path}`;
  }
```

Change the `call` signature/usage to allow a per-call base. Update the `init` param type and the `fetchImpl` line:

```typescript
  async function call<T>(
    method: string,
    path: string,
    init?: { body?: unknown; headers?: Record<string, string>; baseUrl?: string },
  ): Promise<T> {
    ...
      res = await fetchImpl(url(path, init?.baseUrl), requestInit);
    ...
  }
```

In `uploadMedia`, route the call to the media base:

```typescript
      const data = await call<unknown>("POST", "/media/upload", { body: fd, baseUrl: mediaBaseUrl });
```

- [ ] **Step 4: Run to verify pass + full suite**

Run: `npm test -- src/api-client.test.ts` then `npm test`
Expected: PASS — new test + the existing "uploadMedia POSTs multipart" test (no `mediaBaseUrl` → `mediaBaseUrl === baseUrl`) both green.

- [ ] **Step 5: Commit**

```bash
git add src/api-client.ts src/api-client.test.ts
git commit -m "feat: openclaw api client routes /media/upload to mediaBaseUrl"
```

---

### Task 15: Plumb `mediaBaseUrl` at client instantiation + manifest

**Files:**
- Modify: `src/runtime.ts`, `src/outbound.ts`, `openclaw.plugin.json`

- [ ] **Step 1: Find every api-client instantiation** that passes `baseUrl: account.baseUrl`:

Run: `grep -rn "baseUrl: account.baseUrl" src`
Expected: at least `src/runtime.ts` and `src/outbound.ts`.

- [ ] **Step 2: Add `mediaBaseUrl: account.mediaBaseUrl,`** immediately after each `baseUrl: account.baseUrl,` line found. For `src/runtime.ts`:

```typescript
    conversationApiClient ??= createOpenclawClawlingApiClient({
      baseUrl: account.baseUrl,
      mediaBaseUrl: account.mediaBaseUrl,
      token: account.token,
      userId: account.userId,
    });
```

For `src/outbound.ts`:

```typescript
      const apiClient = createOpenclawClawlingApiClient({
        baseUrl: account.baseUrl,
        mediaBaseUrl: account.mediaBaseUrl,
        token: account.token,
        userId: account.userId,
      });
```

- [ ] **Step 3: Update `openclaw.plugin.json`** — add `"CLAWCHAT_MEDIA_BASE_URL"` to the `channelEnvVars["clawchat-plugin-openclaw"]` array (after `"CLAWCHAT_WEBSOCKET_URL"`), and add `"mediaBaseUrl": { "type": "string" },` to the channel `configSchema.properties` (after `"baseUrl": { "type": "string" },`). If a `channelConfigs.*.schema` block also lists `baseUrl`, add `mediaBaseUrl` there too — verify with:

Run: `grep -n "baseUrl" openclaw.plugin.json`
Add a sibling `mediaBaseUrl` line at each `"baseUrl": { "type": "string" }` occurrence.

- [ ] **Step 4: Run the full suite + typecheck**

Run: `npm test` then `npm run typecheck` (if defined; otherwise `npx tsc --noEmit`)
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/runtime.ts src/outbound.ts openclaw.plugin.json
git commit -m "feat: thread mediaBaseUrl through openclaw client + manifest"
```

---

# Phase 4 — verification

### Task 16: Cross-repo build/test sweep + manual smoke

- [ ] **Step 1: install CLI** — from `clawchat-plugin-install-cli/`:

Run: `pnpm test && pnpm typecheck && pnpm build`
Expected: all PASS.

- [ ] **Step 2: hermes plugin** — from `clawchat-plugin-hermes-agent/`:

Run: `uv run pytest -q`
Expected: PASS.

- [ ] **Step 3: openclaw plugin** — from `clawchat-plugin-openclaw/`:

Run: `npm test`
Expected: PASS.

- [ ] **Step 4: Dry-run the CLI parsing** (no host side effects — uses a temp HOME) from `clawchat-plugin-install-cli/`:

```bash
HOME="$(mktemp -d)" node packages/cli/dist/index.js install \
  --target openclaw@dev \
  --apibaseurl example.test:39001 \
  --wsbaseurl example.test:39002 \
  --mediabaseurl example.test:39003 || true
cat "$HOME/.openclaw/openclaw.json"
```

Expected: the command fails at the real `openclaw plugins install` step (no openclaw installed) — that's fine — BUT before failing it writes `~/.openclaw/openclaw.json`. Confirm it contains:
```json
"clawchat-plugin-openclaw": {
  "baseUrl": "https://example.test:39001",
  "websocketUrl": "wss://example.test:39002/ws",
  "mediaBaseUrl": "https://example.test:39003"
}
```

> Verifies the "write before install" ordering end-to-end with placeholder hosts.

- [ ] **Step 5: Verify the Hermes host accepts a git#branch spec** — manual, against a live Hermes Agent (the one repo-unconfirmable assumption). If `hermes plugins install <giturl>#<branch>` is rejected by the host CLI, the only change needed is the spec form built in `installHermesFromRef` (Task 7); the rest of the pipeline is unaffected. Document the result in the PR description.

- [ ] **Step 6 (optional): bump aggregator submodule pins** — from the aggregator root, per `clawchat-agent-plugin/CLAUDE.md`, when pushing:

```bash
git add clawchat-plugin-install-cli clawchat-plugin-hermes-agent clawchat-plugin-openclaw
git commit -m "chore: bump submodule pins for base-url install flags"
```

---

## Self-review notes

- **Spec coverage:** `--apibaseurl/--wsbaseurl/--mediabaseurl` (Tasks 1,8), normalization assume-TLS (Task 1), `@`-target openclaw version (Tasks 2,6) + hermes git#branch with branch-aware yaml (Tasks 2,7), write-before-install to `.env`/`openclaw.json` (Tasks 3,4,6,7), dedicated media slot Hermes (Tasks 10–12) + OpenClaw (Tasks 13–15), WS/REST unchanged in plugins (no task — already resolved via config→env→default), README placeholders (Task 9), `install-dev.sh` untouched (not modified anywhere). All covered.
- **Type consistency:** `BaseUrlOverrides`/`BaseUrlWriter`/`InstallerOptions` (Task 5) consumed identically in Tasks 6–8; `ParsedTarget.{host,ref}` used in Task 8; `mediaBaseUrl`/`media_base_url` names consistent across Tasks 10–15.
- **No host literals** committed to plugin source/docs; examples use `example.test`/placeholders.
- **Unconfirmed assumption** isolated to Task 16 Step 5 (hermes git#branch host support); failure mode is contained to one function.
