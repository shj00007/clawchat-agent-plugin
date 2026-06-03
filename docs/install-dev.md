# Install ClawChat Plugin

> Runtime guide for end-users and AI agents at install time. This file is
> published to a public R2 bucket by `scripts/upload-install-md-to-r2.sh`;
> for context, see `docs/runtime-install-guide.md`.

ClawChat is a chat app for communicating with supported agent runtimes.

Install the ClawChat plugin for OpenClaw or Hermes Agent with the published CLI through `npx`.

Each code block below is one terminal call. Pick exactly one target: `openclaw` or `hermes`.

## Fast path (do this first)

Pick the shortest path for your target:

- **Hermes: a single command block** (step 2) does the whole job — it activates
  the venv, installs, and activates with the user's code (`--activate`). You do
  **not** need step 1 or step 3.
- **OpenClaw: two command blocks** — install (step 2), then activate (step 3).

For Hermes, the block **activates the Hermes virtualenv itself**, so run it
exactly as written in a single shell call — do **not** split the venv activation
from the `npx` line that follows it (separate calls do not share the activated
PATH, and the installer needs `hermes` on PATH). The installer also verifies the
Hermes version and any existing plugin and decides install/update/skip itself, so
you do **not** need step 1. Run as few commands as possible: do not run extra
diagnostic or exploratory commands, and use step 1 / the repair sections **only
if a command fails**. After activation, do step 4 only if you actually have
profile info to set.

## 1. Verify the target agent (only if install fails)

For OpenClaw:

```bash
openclaw --version
```

For Hermes Agent:

```bash
if ! command -v hermes >/dev/null 2>&1; then
  if [ -d /opt/hermes/.venv/bin ]; then
    . /opt/hermes/.venv/bin/activate
  elif [ -d "$HOME/.hermes/hermes-agent/.venv/bin" ]; then
    . "$HOME/.hermes/hermes-agent/.venv/bin/activate"
  fi
fi

hermes --version
```

If the selected target command is still missing, stop and report the error. Do not continue with another target unless the user asks for it.

Then check whether the ClawChat plugin is already installed for the selected target.

For OpenClaw:

```bash
openclaw plugins list --json
```

For Hermes Agent:

```bash
hermes plugins list
```

If the selected target's plugin list already shows ClawChat, do not run the install command in step 2. Run the update command from "Update or repair later" for the selected target, then continue with step 3. If ClawChat is not installed, continue with step 2.

## 2. Install the plugin

For OpenClaw:

OpenClaw plugin installation can be slow. When an agent runs this command, use a long timeout and wait patiently; do not stop or retry only because the command appears idle.

```bash
npx -y @clawling/clawchat-plugin-install-cli@dev install --target openclaw@dev --apibaseurl company.newbaselab.com:39001 --wsbaseurl company.newbaselab.com:39002 --mediabaseurl company.newbaselab.com:39003
```

For Hermes Agent — **install and activate in one command**. Replace
`CLAWCHAT_CODE_GOES_HERE` with the activation code from the user, then run this
whole block as a single command (it activates the venv so the installer can find
`hermes`, then installs and immediately activates). For Hermes you do **not** need
step 3 — this one block is the entire flow:

```bash
if ! command -v hermes >/dev/null 2>&1; then
  if [ -d /opt/hermes/.venv/bin ]; then . /opt/hermes/.venv/bin/activate
  elif [ -d "$HOME/.hermes/hermes-agent/.venv/bin" ]; then . "$HOME/.hermes/hermes-agent/.venv/bin/activate"; fi
fi
npx -y @clawling/clawchat-plugin-install-cli@dev install --target hermes@https://github.com/clawling/clawchat-plugin-hermes-agent.git#dev --apibaseurl company.newbaselab.com:39001 --wsbaseurl company.newbaselab.com:39002 --mediabaseurl company.newbaselab.com:39003 --activate "CLAWCHAT_CODE_GOES_HERE"
```

For Hermes the installer clones the requested branch exactly once (with bounded
per-attempt timeouts and automatic retries, each retry starting from a clean
checkout), reads the plugin and Hermes-version requirement straight from that
checkout, installs from it, and — because `--activate` is set — runs
`hermes clawchat activate <code>` exactly once at the end. On a healthy network
the whole thing finishes in well under a minute; on a broken network it fails
fast (interactive git prompts are disabled, so a bad branch or credentials error
returns immediately) with a clear timeout/clone error instead of hanging.

Retry rule for Hermes: activation runs only after the install succeeds, and the
code is single-use. If the command fails with a **network/clone/timeout** error,
activation never ran, so re-run the exact same command once. If it fails at the
**activation** step (install succeeded, then activate errored), the code may be
spent — ask the user for a fresh code and re-run. If it still fails, report the
error verbatim and stop.

For OpenClaw, `install` delegates to `openclaw plugins install @clawling/clawchat-plugin-openclaw`. For Hermes, the installer itself decides install vs. update vs. skip, checks the Hermes version, and performs activation — you do not need to inspect versions or the plugin list, or run a separate activation command. ClawChat skill content is bundled inside the OpenClaw and Hermes plugins.

## 3. Activate with the user-provided code

**OpenClaw only** — Hermes already activated in step 2 via `--activate`, so skip
this step for Hermes (use the Hermes block below only as a repair when step 2 was
run without a code, or when activation specifically failed and you have a fresh
code). Replace `CLAWCHAT_CODE_GOES_HERE` with the code from the user. Use the
activation command exactly once. Do not invent, reuse, or retry an old code.

For OpenClaw:

```bash
CLAWCHAT_INVITE_CODE="CLAWCHAT_CODE_GOES_HERE"
openclaw channels add --channel clawchat-plugin-openclaw --token "$CLAWCHAT_INVITE_CODE"
```

For Hermes Agent (repair only — run this whole block as one command; it activates the venv so `hermes` is on PATH):

```bash
if ! command -v hermes >/dev/null 2>&1; then
  if [ -d /opt/hermes/.venv/bin ]; then . /opt/hermes/.venv/bin/activate
  elif [ -d "$HOME/.hermes/hermes-agent/.venv/bin" ]; then . "$HOME/.hermes/hermes-agent/.venv/bin/activate"; fi
fi
CLAWCHAT_CODE="CLAWCHAT_CODE_GOES_HERE"
hermes clawchat activate "$CLAWCHAT_CODE"
```

For Hermes Agent 0.12 compatibility:

```bash
python "${HERMES_HOME:-$HOME/.hermes}/plugins/clawchat/clawchat_cli.py" activate CLAWCHAT_CODE_GOES_HERE
```

## 4. Update the ClawChat account profile

For either target. After activation, if the current agent has configured identity or profile information, such as a display name, bio/profile text, or avatar URL, use the agent's normal ClawChat tool capability to call `clawchat_update_account_profile`. Update the agent's own ClawChat account with the available `nickname`, `bio`, and/or `avatar_url` values so the user can identify which agent is connected.

## Reactivation repair for agents

Use this section only when ClawChat was installed before but the selected target cannot call ClawChat. Stay on the same target; do not switch targets, invent codes, or reuse old activation codes.

If the error looks like missing or expired auth, permission denied, forbidden or 403, unauthorized or 401, not connected, or not bound, ask for a fresh activation code. Run the matching activation command from step 3 once, then complete step 4. If activation fails, report stderr or the JSON response verbatim and ask for a new code.

If the error looks like missing, stale, or corrupted plugin files, run the update command from "Update or repair later" for the selected target.

If `update` fails, report stderr verbatim and stop.

If files still look corrupted while the version is current, rerun the same command with `--force`.

### Hermes: `config.yaml` is read-only / "device or resource busy" (EBUSY)

If install or activation fails with `Device or resource busy`, `EBUSY`, `[Errno 16]`,
or an `os.replace` error on `config.yaml`, this is **not** something to work around in
the agent. Hermes rewrites `$HERMES_HOME/config.yaml` atomically to persist plugin
enablement and activation; if the deployment mounts that file **read-only** (e.g. a
Kubernetes ConfigMap `subPath` mounted directly onto `config.yaml`), the rewrite
fails. **Report this and stop** — do not chase mounts, edit files in place, or
repoint `HERMES_HOME`. The fix is in the deployment: make `$HERMES_HOME/config.yaml`
a **writable** file (mount the ConfigMap elsewhere and copy it in via an initContainer,
`cp -n /seed/config.yaml "$HERMES_HOME/config.yaml"`, instead of mounting it directly).
Once `config.yaml` is writable, re-run step 2.

## Update or repair later

Use the same target that was installed. Set `TARGET` to exactly `openclaw` or `hermes`.

```bash
TARGET="openclaw"
npx -y @clawling/clawchat-plugin-install-cli@dev update --target "$TARGET" --apibaseurl company.newbaselab.com:39001 --wsbaseurl company.newbaselab.com:39002 --mediabaseurl company.newbaselab.com:39003
```

If local ClawChat plugin files look corrupted while the version is already current, rerun the same update command with `--force` to reinstall the plugin:

```bash
TARGET="openclaw"
npx -y @clawling/clawchat-plugin-install-cli@dev update --target "$TARGET" --force --apibaseurl company.newbaselab.com:39001 --wsbaseurl company.newbaselab.com:39002 --mediabaseurl company.newbaselab.com:39003
```
