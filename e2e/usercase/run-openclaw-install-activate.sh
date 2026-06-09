#!/usr/bin/env bash
#
# e2e 测试用例：openclaw agent 对话式安装 + 激活 + 连接 ClawChat（test env）
#
# 目标：尽量复刻真实用户链路 —— 用户已配好 LLM key，并通过【对话式聊天】让 agent
# 自己按 install-dev.md 安装+激活 clawchat 插件，而非人工敲安装命令。对照 Hermes 的
# run-hermes-install-activate.sh。
#
#   1. 起 openclaw e2e 环境（见 ../openclaw-agent-e2e.md）；把 seed 配置改成贴近真实部署：
#      移除预置的 channel 块（真实新装没有它），设 gateway.mode=local（模拟已 onboard 的 gateway）。
#   2. 向 member-backend 申请 agent 连接码（curl，JWT 取自 ../.env）。
#   3. 给 agent 发 prompt，让它按 install-dev.md 走 OpenClaw 路径：step2 `npx … install
#      --target openclaw@dev …`（含 install-cli 顺序修正，需 clawchat-plugin-install-cli@dev）
#      + step3 `openclaw channels add --token <code>`。
#   4. 拉起 `node openclaw.mjs gateway`（前台 + timeout，捕获日志），轮询 WebSocket 握手。
#
# 成功判定：硬超时（默认 180s）内，gateway 日志出现 `event=handshake_ok`。超时即中断、
#           打印诊断、返回非 0。
#
# 全程目标后端 = company.newbaselab.com（test env）。connect-code / 安装 / 激活同后端。
#
# 用法：
#   cp ../.env.example ../.env && 编辑填入 CLAWCHAT_JWT、LLM_API_KEY
#   ./run-openclaw-install-activate.sh            # 跑完默认保留环境
#   KEEP=0 ./run-openclaw-install-activate.sh     # 跑完彻底销毁环境
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_DIR="$(cd "$HERE/.." && pwd)"

# ── 载入配置 ──────────────────────────────────────────────────────────────
if [[ -f "$E2E_DIR/.env" ]]; then
  set -a; . "$E2E_DIR/.env"; set +a
else
  echo "✗ 缺少 $E2E_DIR/.env（从 .env.example 复制并填 CLAWCHAT_JWT / LLM_API_KEY）" >&2; exit 2
fi

: "${CLAWCHAT_JWT:?请在 .env 设置 CLAWCHAT_JWT（移动端用户 Bearer JWT）}"
: "${LLM_API_KEY:?请在 .env 设置 LLM_API_KEY（clawling 网关 key，sk-crawling-…；agent 推理用）}"
API_BASE="${API_BASE:-https://company.newbaselab.com:39001}"
DEVICE_ID="${DEVICE_ID:-apifox}"
NAMESPACE="${NAMESPACE:-joe-clawchat-dev}"
OPENCLAW_IMAGE_TAG="${OPENCLAW_IMAGE_TAG:-v2026.5.27}"
OPENCLAW_SESSION_KEY="${OPENCLAW_SESSION_KEY:-agent:default:smoke-test}"
MODEL="${MODEL:-deepseek-v4-flash}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-180}"
KEEP="${KEEP:-1}"   # 1=跑完保留环境（默认），0=彻底销毁
eval KUBECONFIG_PATH="${KUBECONFIG_PATH:-~/.kube/dev.config}"
export KUBECONFIG="$KUBECONFIG_PATH"

APP=openclaw-smoke
OC_CONFIG="/home/node/.openclaw/openclaw.json"
OC_CHANNEL="clawchat-plugin-openclaw"

# 复用通用启动（manifest/secret/apply/teardown 的唯一来源）
source "$E2E_DIR/lib/openclaw-env.sh"

command -v jq   >/dev/null || { echo "✗ 需要 jq"   >&2; exit 2; }
command -v curl >/dev/null || { echo "✗ 需要 curl" >&2; exit 2; }
kc() { kubectl -n "$NAMESPACE" "$@"; }

now()  { date +%s; }
log()  { echo -e "[$(date +%H:%M:%S)] $*"; }
fail() { echo -e "\n✗ FAIL: $*" >&2; diagnostics; exit 1; }

POD=""
GW_OUT=""
AGENT_OUT=""
diagnostics() {
  echo -e "\n──────── 诊断 ────────" >&2
  [[ -n "$POD" ]] || POD="$(running_pod || true)"
  if [[ -n "$POD" ]]; then
    echo "[gateway 输出末尾]" >&2
    tail -n 40 "${GW_OUT:-/dev/null}" 2>/dev/null >&2 || true
    echo "[openclaw.json channels/gateway]" >&2
    kc exec -i "$POD" -- python3 - <<PY >&2 2>/dev/null || true
import json
try:
    d = json.load(open("$OC_CONFIG"))
    ch = d.get("channels", {}).get("$OC_CHANNEL", {})
    print("  channel keys:", sorted(ch.keys()), "has_token:", bool(ch.get("token")))
    print("  gateway.mode:", d.get("gateway", {}).get("mode"))
except Exception as e:
    print("  (read config failed:", e, ")")
PY
    echo "[plugins list]" >&2
    kc exec "$POD" -- sh -lc 'node openclaw.mjs plugins list 2>&1 | grep -i clawchat' >&2 2>/dev/null || true
    echo "[install/activate agent 输出末尾]" >&2
    tail -n 25 "${AGENT_OUT:-/dev/null}" 2>/dev/null >&2 || true
  fi
  echo "──────────────────────" >&2
}

running_pod() {
  kc get pod -l app="$APP" --field-selector=status.phase=Running \
     -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# 激活完成？openclaw.json 的 clawchat channel 已写入非空 token（`channels add` 最后一步）。
activated_check() {
  kc exec -i "$POD" -- python3 - <<PY 2>/dev/null
import json, sys
try:
    d = json.load(open("$OC_CONFIG"))
    if (d.get("channels", {}).get("$OC_CHANNEL", {}) or {}).get("token"):
        sys.exit(0)
except Exception:
    pass
sys.exit(1)
PY
}

# 安装「已完成或正在进行」？plugin 目录已存在，或还有 install-cli/npx 进程在跑。
# 用于区分「模型卡在生成工具调用、没跑命令」（无进展，提前止损）与「命令在执行」（有进展）。
install_active_or_done() {
  kc exec "$POD" -- sh -lc \
    'test -d /home/node/.openclaw/npm/node_modules/@clawling/clawchat-plugin-openclaw || pgrep -f "[c]lawchat-plugin-install-cli" >/dev/null' \
    2>/dev/null
}

# 连接成功？gateway 前台输出里出现 handshake_ok（host 侧 $GW_OUT 即 gateway stdout）。
connected_check() {
  [[ -n "$GW_OUT" ]] && grep -aq 'event=handshake_ok' "$GW_OUT" 2>/dev/null
}

# 把 seed 配置改成贴近真实部署：移除预置 channel 块（真实新装没有它，留着会让
# `openclaw plugins install` 校验失败）+ 设 gateway.mode=local（模拟已 onboard 的 gateway）。
realisticize_config() {
  kc exec -i "$POD" -- python3 - <<PY 2>/dev/null
import json
p = "$OC_CONFIG"
d = json.load(open(p))
d["channels"] = {}                      # 真实新装：无预置 channel；install 会写回
d.setdefault("gateway", {})["mode"] = "local"
json.dump(d, open(p, "w"), indent=2)
print("ok")
PY
}

# 彻底删除本用例全部资源（含 PVC）并等 Pod 真正消失。
teardown() {
  openclaw_env_down >/dev/null 2>&1 || true
  local waited=0
  while [[ -n "$(kc get pods -l app="$APP" -o name 2>/dev/null)" ]] && (( waited < 60 )); do
    sleep 2; waited=$((waited + 2))
  done
}

# ── 1. 起 openclaw e2e 环境 ────────────────────────────────────────────────
log "① 起 openclaw e2e 环境（ns=$NAMESPACE, tag=$OPENCLAW_IMAGE_TAG）"
log "   清理上一轮残留（含 PVC）以确保全新环境..."
teardown
openclaw_env_up || fail "起 openclaw e2e 环境失败（openclaw_env_up）"
POD="$(openclaw_env_pod)" || fail "找不到 Running pod"
log "   ✓ 环境就绪：POD=$POD"

kc exec "$POD" -- sh -lc 'command -v npx >/dev/null' \
  || fail "pod 内没有 npx —— openclaw 镜像缺 node，无法跑 install-cli"

log "   调整 seed 配置贴近真实部署（移除预置 channel 块 + gateway.mode=local）"
realisticize_config | grep -q ok || fail "调整 openclaw.json 失败"

# ── 2. 申请连接码 ─────────────────────────────────────────────────────────
log "② 申请 agent 连接码（POST $API_BASE/v1/agents/connect-codes）"
RESP="$(curl -sS -m 30 --location --request POST "$API_BASE/v1/agents/connect-codes" \
  --header "Authorization: Bearer $CLAWCHAT_JWT" \
  --header "x-device-id: $DEVICE_ID" \
  --header "Content-Type: application/json" \
  --data-raw '{"force": true}')" || fail "连接码接口请求失败（网络/host 不通？）"
ENV_CODE="$(printf '%s' "$RESP" | jq -r '.code // empty')"
[[ "$ENV_CODE" == "0" ]] \
  || fail "连接码接口返回非成功 $(printf '%s' "$RESP" | jq -rc '{code,msg}')（401/invalid token 多为 JWT 非本环境签发）"
CODE="$(printf '%s' "$RESP" | jq -r '.data.code // empty')"
[[ -n "$CODE" && "$CODE" != "null" ]] || fail "未解析出连接码，原始响应：$RESP"
log "   code=$CODE expires_at=$(printf '%s' "$RESP" | jq -r '.data.expires_at // "?"')"

# ── 计时开始：安装→激活→连接 的 3 分钟硬窗口 ────────────────────────────────
DEADLINE=$(( $(now) + TIMEOUT_SECONDS ))
remaining() { local r=$(( DEADLINE - $(now) )); (( r > 0 )) && echo "$r" || echo 0; }

# ── 3. 发 prompt：对话式安装 + 激活 ────────────────────────────────────────
# 预取 install-dev.md 到 pod（绕开 pod 的 IPv6 黑洞；curl -4），让 agent 读本地文件执行。
DOC_URL="https://plugin.clawling.chat/clawchat/install-dev.md"
DOC_LOCAL="/home/node/install-dev.md"
log "③ 预取 install-dev.md 到 pod（绕开 pod 的 IPv6 黑洞；curl -4）"
DOC_CONTENT="$(curl -fsSL -4 -m 30 "$DOC_URL")" || fail "拉取 install-dev.md 失败（$DOC_URL）"
printf '%s' "$DOC_CONTENT" | kc exec -i "$POD" -- sh -lc "cat > '$DOC_LOCAL'" \
  || fail "写入 $DOC_LOCAL 失败"
PROMPT="Strictly follow the instructions in the local file ${DOC_LOCAL} to install and activate the clawchat plugin for OpenClaw. Read it with: cat ${DOC_LOCAL}. Run step 2 (install with --target openclaw@dev) and then step 3 (activate). The active code is ${CODE}. Do NOT start the gateway yourself."
AGENT_OUT="$(mktemp)"
GW_OUT="$(mktemp)"

# ── 4. 安装 + 激活：有界 agent turn + 失败重试（呼应 Hermes 对 LLM 抖动的免疫策略）──────
SUCCESS=0; ACTIVATED=0; ATTEMPT=0
HUNG_KILL_AFTER=40   # openclaw 首调偶发 ~2min terminated，给比 hermes 略宽的无进展窗口
while (( ACTIVATED == 0 )) && (( $(remaining) > 40 )); do
  ATTEMPT=$((ATTEMPT + 1))
  TURN_BUDGET=$(( $(remaining) - 25 )); (( TURN_BUDGET > 80 )) && TURN_BUDGET=80
  log "④.${ATTEMPT} agent turn（预算 ${TURN_BUDGET}s，总剩余 $(remaining)s）：对话式安装+激活，轮询凭据落库..."
  ( timeout "$TURN_BUDGET" kubectl -n "$NAMESPACE" exec "$POD" -- node openclaw.mjs agent --local \
      --model "deepseek/${MODEL}" --session-key "${OPENCLAW_SESSION_KEY}" -m "$PROMPT" \
      >"$AGENT_OUT" 2>&1 ) &
  AGENT_PID=$!
  tstart=$(now)
  while kill -0 "$AGENT_PID" 2>/dev/null && (( $(remaining) > 0 )); do
    if activated_check; then ACTIVATED=1; break; fi
    if (( $(now) - tstart >= HUNG_KILL_AFTER )) && ! install_active_or_done; then
      log "   ④.${ATTEMPT} ${HUNG_KILL_AFTER}s 无安装进展（疑似模型卡在生成工具调用）→ 提前止损"
      break
    fi
    sleep 3
  done
  kill "$AGENT_PID" 2>/dev/null || true
  wait "$AGENT_PID" 2>/dev/null
  if (( ACTIVATED == 0 )) && activated_check; then ACTIVATED=1; fi
  (( ACTIVATED == 1 )) && break
  log "   第 ${ATTEMPT} 次 agent turn 未完成激活（多半模型卡顿）→ 重试（总剩余 $(remaining)s）"
done

# ── 5. 起 gateway（前台 + timeout，捕获 stdout），轮询握手 ──────────────────
if (( ACTIVATED == 1 )); then
  log "   激活完成 → 拉起 gateway（node openclaw.mjs gateway）→ 轮询 WebSocket 握手（总剩余 $(remaining)s）"
  ( timeout "$(remaining)" kubectl -n "$NAMESPACE" exec "$POD" -- node openclaw.mjs gateway \
      >"$GW_OUT" 2>&1 ) &
  GW_PID=$!
  while kill -0 "$GW_PID" 2>/dev/null && (( $(remaining) > 0 )); do
    if connected_check; then SUCCESS=1; break; fi
    sleep 3
  done
  kill "$GW_PID" 2>/dev/null || true
  wait "$GW_PID" 2>/dev/null
else
  log "   未完成激活（agent 未在预算内装好/激活）"
fi

ELAPSED=$(( TIMEOUT_SECONDS - $(remaining) ))
if (( SUCCESS == 1 )); then
  log "\n✓ PASS：插件对话式安装并连接成功，用时约 ${ELAPSED}s（≤ ${TIMEOUT_SECONDS}s）"
  RC=0
else
  echo -e "\n✗ FAIL：超过 ${TIMEOUT_SECONDS}s 仍未连接，已中断。" >&2
  diagnostics
  RC=1
fi

# ── 清理 ──────────────────────────────────────────────────────────────────
if [[ "$KEEP" == "0" ]]; then
  log "清理环境（KEEP=0，含 PVC 残留）"
  teardown
else
  log "环境保留（KEEP=1）。彻底销毁（含 PVC）：$E2E_DIR/lib/openclaw-env.sh down"
fi
rm -f "$AGENT_OUT" "$GW_OUT"
exit "$RC"
