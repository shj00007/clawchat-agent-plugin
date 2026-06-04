#!/usr/bin/env bash
#
# e2e 测试用例：hermes agent 一键安装 + 激活 + 连接 ClawChat（test env）
#
#   1. 起 hermes e2e 环境镜像（见 ../hermes-agent-e2e.md）
#   2. 向 member-backend 申请 agent 连接码（curl，JWT 取自 ../.env）
#   3. 给 agent 发 prompt，让它按 install-dev.md 安装并用连接码激活 clawchat 插件
#   4. 拉起 hermes gateway，轮询 WebSocket 是否握手成功（连接上）
#
# 成功判定：在硬超时（默认 180s / 3 分钟）内观察到 `clawchat.ws event=handshake_ok`
#           或 SQLite connections.state='ready'。超时即中断并打印诊断、返回非 0。
#
# 全程目标后端 = company.newbaselab.com（test env）。connect-code / 安装 / 激活
# 必须是同一后端，否则激活失败。install-dev.md@dev 默认即指向该后端。
#
# 用法：
#   cp ../.env.example ../.env && 编辑填入 CLAWCHAT_JWT
#   ./run-hermes-install-activate.sh            # 跑完默认保留环境
#   KEEP=0 ./run-hermes-install-activate.sh     # 跑完彻底销毁环境
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_DIR="$(cd "$HERE/.." && pwd)"

# ── 载入配置 ──────────────────────────────────────────────────────────────
if [[ -f "$E2E_DIR/.env" ]]; then
  set -a; . "$E2E_DIR/.env"; set +a
else
  echo "✗ 缺少 $E2E_DIR/.env（从 .env.example 复制并填 CLAWCHAT_JWT）" >&2; exit 2
fi

: "${CLAWCHAT_JWT:?请在 .env 设置 CLAWCHAT_JWT（移动端用户 Bearer JWT）}"
: "${LLM_API_KEY:?请在 .env 设置 LLM_API_KEY（clawling 网关 key，sk-crawling-…；agent 推理用）}"
API_BASE="${API_BASE:-https://company.newbaselab.com:39001}"
DEVICE_ID="${DEVICE_ID:-apifox}"
NAMESPACE="${NAMESPACE:-joe-clawchat-dev}"
HERMES_IMAGE_TAG="${HERMES_IMAGE_TAG:-v2026.5.27}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-180}"
KEEP="${KEEP:-1}"   # 1=跑完保留环境（默认），0=彻底销毁
eval KUBECONFIG_PATH="${KUBECONFIG_PATH:-~/.kube/dev.config}"
export KUBECONFIG="$KUBECONFIG_PATH"

APP=hermes-agent-smoke

# 复用通用启动（manifest/secret/apply/teardown 的唯一来源）
source "$E2E_DIR/lib/hermes-env.sh"

command -v jq   >/dev/null || { echo "✗ 需要 jq"   >&2; exit 2; }
command -v curl >/dev/null || { echo "✗ 需要 curl" >&2; exit 2; }
kc() { kubectl -n "$NAMESPACE" "$@"; }

now()  { date +%s; }
log()  { echo -e "[$(date +%H:%M:%S)] $*"; }
fail() { echo -e "\n✗ FAIL: $*" >&2; diagnostics; exit 1; }

POD=""
diagnostics() {
  echo -e "\n──────── 诊断 ────────" >&2
  [[ -n "$POD" ]] || POD="$(running_pod || true)"
  if [[ -n "$POD" ]]; then
    echo "[gateway.log 末尾]" >&2
    kc exec "$POD" -- bash -lc 'tail -n 40 /opt/data/gateway.log 2>/dev/null' >&2 || true
    echo "[activations / connections]" >&2
    kc exec -i "$POD" -- python3 - <<'PY' >&2 2>/dev/null || true
import os, sqlite3
db = "/opt/data/clawchat.sqlite"
if not os.path.exists(db):
    print("  (no clawchat.sqlite — 激活未发生)"); raise SystemExit
c = sqlite3.connect(db)
def q(sql):
    try: return c.execute(sql).fetchall()
    except Exception as e: return [("err", str(e))]
for r in q("select platform, substr(user_id,1,14) from activations"):
    print("  act:", r)
for r in q("select state, created_at from connections order by created_at desc limit 3"):
    print("  conn:", r)
PY
    echo "[install/activate agent 输出末尾]" >&2
    tail -n 25 "${AGENT_OUT:-/dev/null}" 2>/dev/null >&2 || true
  fi
  echo "──────────────────────" >&2
}

running_pod() {
  kc get pod -l app="$APP" --field-selector=status.phase=Running \
     -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# 激活完成？sqlite activations 表已落库一行（激活最后一步，提交后才可见）。
# 退出码 0=已激活。一旦激活，凭据(.env CLAWCHAT_TOKEN + sqlite)已写好，可安全停掉
# agent turn 并独占地拉起 gateway——不必空等弱模型把整个会话跑满。只读，不干扰激活。
activated_check() {
  kc exec -i "$POD" -- python3 - <<'PY' 2>/dev/null
import os, sqlite3, sys
db = "/opt/data/clawchat.sqlite"
try:
    if os.path.exists(db):
        row = sqlite3.connect(db).execute("select 1 from activations limit 1").fetchone()
        if row:
            sys.exit(0)
except Exception:
    pass
sys.exit(1)
PY
}

# 安装是否「已完成或正在进行」？plugin 目录已存在，或还有 install-cli/npx 进程在跑。
# 退出码 0=有进展。用于区分「模型卡在生成工具调用、压根没跑命令」（无进展）与「命令在
# 正常执行（含冷网络重试克隆）」（有进展），从而只对前者提前止损、不误杀后者。
install_active_or_done() {
  # `[c]…` bracket trick: the regex matches a real npx/node install-cli process
  # but NOT pgrep's own command line (which contains the literal "[c]lawchat…"),
  # avoiding a false positive that would suppress the hung-kill below.
  kc exec "$POD" -- bash -lc \
    'test -d /opt/data/plugins/clawchat || pgrep -f "[c]lawchat-plugin-install-cli" >/dev/null' \
    2>/dev/null
}

# 连接成功？日志有 handshake_ok 或 connections.state=ready。退出码 0=连上。
# 镜像内没有 sqlite3 CLI（实测 exit 127），改用容器自带 python3 读库。
connected_check() {
  kc exec -i "$POD" -- python3 - <<'PY' 2>/dev/null
import os, sqlite3, sys
log = "/opt/data/gateway.log"
try:
    if os.path.exists(log) and "clawchat.ws event=handshake_ok" in open(log, encoding="utf-8", errors="ignore").read():
        sys.exit(0)
except Exception:
    pass
db = "/opt/data/clawchat.sqlite"
try:
    if os.path.exists(db):
        row = sqlite3.connect(db).execute(
            "select 1 from connections where state='ready' limit 1").fetchone()
        if row:
            sys.exit(0)
except Exception:
    pass
sys.exit(1)
PY
}

# 彻底删除本用例全部资源（含 PVC）并等 Pod 真正消失。删除动作交给通用 lib（唯一来源）。
teardown() {
  hermes_env_down >/dev/null 2>&1 || true
  local waited=0
  while [[ -n "$(kc get pods -l app="$APP" -o name 2>/dev/null)" ]] && (( waited < 60 )); do
    sleep 2; waited=$((waited + 2))
  done
}

# ── 1. 起 hermes e2e 环境 ─────────────────────────────────────────────────
log "① 起 hermes e2e 环境（ns=$NAMESPACE, tag=$HERMES_IMAGE_TAG）"
log "   清理上一轮残留（含 PVC）以确保全新环境..."
teardown
hermes_env_up || fail "起 hermes e2e 环境失败（hermes_env_up）"
POD="$(hermes_env_pod)" || fail "找不到 Running pod"
log "   ✓ 环境就绪：POD=$POD"

# 前置检查：agent 安装插件靠 npx（install-cli 经 npx 分发），镜像内必须有 node/npx。
kc exec "$POD" -- bash -lc 'command -v npx >/dev/null' \
  || fail "pod 内没有 npx —— hermes 镜像缺 node，无法跑 install-cli（确认镜像或改用预装插件方案）"

# ── 2. 申请连接码 ─────────────────────────────────────────────────────────
log "② 申请 agent 连接码（POST $API_BASE/v1/agents/connect-codes）"
RESP="$(curl -sS -m 30 --location --request POST "$API_BASE/v1/agents/connect-codes" \
  --header "Authorization: Bearer $CLAWCHAT_JWT" \
  --header "x-device-id: $DEVICE_ID" \
  --header "Content-Type: application/json" \
  --data-raw '{"force": true}')" || fail "连接码接口请求失败（网络/host 不通？）"
# 返回信封：{"code":0,"data":{"code":"DC2FAQ","expires_at":...},"msg":"ok"}
# 成功 = 顶层 code==0；连接码在 data.code（注意：别拿顶层 code，它是业务状态码）。
ENV_CODE="$(printf '%s' "$RESP" | jq -r '.code // empty')"
[[ "$ENV_CODE" == "0" ]] \
  || fail "连接码接口返回非成功 $(printf '%s' "$RESP" | jq -rc '{code,msg}')（401/invalid token 多为 JWT 非本环境签发）"
CODE="$(printf '%s' "$RESP" | jq -r '.data.code // empty')"
[[ -n "$CODE" && "$CODE" != "null" ]] || fail "未解析出连接码，原始响应：$RESP"
log "   code=$CODE expires_at=$(printf '%s' "$RESP" | jq -r '.data.expires_at // "?"')"

# ── 计时开始：安装→激活→连接 的 3 分钟硬窗口 ────────────────────────────────
DEADLINE=$(( $(now) + TIMEOUT_SECONDS ))
remaining() { local r=$(( DEADLINE - $(now) )); (( r > 0 )) && echo "$r" || echo 0; }

# ── 3. 发 prompt：安装 + 激活 ──────────────────────────────────────────────
# 把已发布的 install-dev.md 预取到 pod 内本地文件，再让 agent 读本地文件执行。
# 原因：dev 集群 pod 的 IPv6 出口是黑洞，agent 直接 `curl https://plugin.clawling.chat/...`
# 会先试 IPv6 卡住 ~140s 才回退 IPv4（实测 -4 仅 ~3s）。这与「安装插件」本身无关，
# 却会吃掉整个 3 分钟预算。预取用 curl -4（宿主机侧，可靠快速），保证测的是
# 真实「安装→激活→连接」链路，而不是 CDN/IPv6 的网络抖动。内容仍是线上发布的同一份文档。
DOC_URL="https://plugin.clawling.chat/clawchat/install-dev.md"
DOC_LOCAL="/opt/data/install-dev.md"
log "③ 预取 install-dev.md 到 pod（绕开 pod 的 IPv6 黑洞；curl -4）"
DOC_CONTENT="$(curl -fsSL -4 -m 30 "$DOC_URL")" || fail "拉取 install-dev.md 失败（$DOC_URL）"
printf '%s' "$DOC_CONTENT" | kc exec -i "$POD" -- bash -lc "cat > '$DOC_LOCAL'" \
  || fail "写入 $DOC_LOCAL 失败"
PROMPT="Strictly follow the instructions in the local file ${DOC_LOCAL} to install and activate the clawchat plugin for Hermes. Read it with: cat ${DOC_LOCAL}. The active code is ${CODE}. The Hermes gateway restart is automatic after activation — do NOT run 'hermes gateway restart' yourself."
AGENT_OUT="$(mktemp)"

# ── 4. 安装 + 激活：有界 agent turn + 失败重试 ───────────────────────────────
# 实测：真实「安装→激活→连上」链路本身只需 ~20s（npx 安装 ~12s、CLI 内联 activate
# ~1s、激活自调度的 detached gateway restart ~6s 后握手）。端到端耗时与成败几乎全取决
# 于 LLM 的 `hermes chat` 这一步——弱模型/网关偶发在「生成工具调用」时卡死，整个会话空
# 转直到被 timeout 杀掉，激活根本没发生（activations=0）。单 turn 跑满 153s 预算的就是
# 这种卡死，而非真在干活。
#
# 对策（呼应需求「网络不通缩减超时进行重拾」）：给每次 agent turn 一个较短预算；turn 进行
# 中只读轮询 activated_check（凭据落库即收工，不空等会话）。若本次 turn 结束仍未激活（多半
# 模型卡死），且时间还够，就重发 prompt 再来一次。连接码一次性，但「未激活」=码没被用过，
# 可安全重试；install 幂等（已装即跳过），CLI 内联 activate 再跑一次即可。仅在确认已激活后
# 才独占拉起 gateway（沿用 ce3825e：gateway 必须在 agent turn 结束后起，避免并发重启打断
# 激活 / 抢占 1-2 核 pod 的 CPU）。
SUCCESS=0; ACTIVATED=0; ATTEMPT=0
# 卡死早杀阈值：进入 turn 这么多秒后若仍「零安装进展」，判定模型卡在生成工具调用，提前止损
# 重试。注意 install_active_or_done 在 npx 一启动就为真（npx argv 里就含包名，连冷网络克隆
# 重试期间也算「有进展」），所以「无进展」窗口仅限模型「发命令前」的思考期；30s 给足余量又
# 不误杀正在干活的 turn。压低它能在预算内塞下更多次重试，从容应对连续多次模型卡死。
HUNG_KILL_AFTER=30
while (( ACTIVATED == 0 )) && (( $(remaining) > 35 )); do
  ATTEMPT=$((ATTEMPT + 1))
  # 单次 turn 预算：留 ~20s 给随后 gateway+握手；封顶 70s。卡死的 turn 由 HUNG_KILL_AFTER
  # 在 ~35s 提前收掉，好把预算让给重试。
  TURN_BUDGET=$(( $(remaining) - 20 )); (( TURN_BUDGET > 70 )) && TURN_BUDGET=70
  log "④.${ATTEMPT} agent turn（预算 ${TURN_BUDGET}s，总剩余 $(remaining)s）：只读轮询激活完成..."
  # NOTE: `timeout` execs an external binary, so it must wrap `kubectl` directly —
  # NOT the `kc` shell function (`timeout kc …` fails instantly with "No such file
  # or directory", so the agent turn never runs: empty output, no activation).
  ( timeout "$TURN_BUDGET" kubectl -n "$NAMESPACE" exec "$POD" -- bash -lc \
      "source /opt/hermes/.venv/bin/activate 2>/dev/null; hermes chat -q $(printf '%q' "$PROMPT")" \
      >"$AGENT_OUT" 2>&1 ) &
  AGENT_PID=$!
  tstart=$(now)
  while kill -0 "$AGENT_PID" 2>/dev/null && (( $(remaining) > 0 )); do
    if connected_check; then SUCCESS=1; ACTIVATED=1; break; fi   # 已连上 → 直接成功
    if activated_check; then ACTIVATED=1; break; fi              # 凭据已落库 → 收工
    # 卡死早杀：超过阈值仍无任何安装进展 → 模型卡在生成工具调用，止损重试。
    if (( $(now) - tstart >= HUNG_KILL_AFTER )) && ! install_active_or_done; then
      log "   ④.${ATTEMPT} ${HUNG_KILL_AFTER}s 无安装进展（疑似模型卡在生成工具调用）→ 提前止损"
      break
    fi
    sleep 3
  done
  # 收掉本次 turn（已激活不必再等；卡死/超时也要止损）。
  kill "$AGENT_PID" 2>/dev/null || true
  wait "$AGENT_PID" 2>/dev/null
  # turn 结束后再确认一次，捕捉「刚好在轮询间隙完成」的激活，避免误重试而用掉刚用的码。
  if (( ACTIVATED == 0 )) && activated_check; then ACTIVATED=1; fi
  (( ACTIVATED == 1 )) && break
  log "   第 ${ATTEMPT} 次 agent turn 未完成激活（多半模型卡顿）→ 重试（总剩余 $(remaining)s）"
done

if (( SUCCESS == 0 )); then
  log "   激活完成(activated=${ACTIVATED}) → 独占拉起 gateway → 轮询 WebSocket 握手（总剩余 $(remaining)s）"
  kc exec "$POD" -- bash -lc \
    'source /opt/hermes/.venv/bin/activate 2>/dev/null; \
     pgrep -f "hermes gateway" >/dev/null || nohup hermes gateway restart >>/opt/data/gateway.log 2>&1 &' \
    >/dev/null 2>&1 || true
  while (( $(remaining) > 0 )); do
    if connected_check; then SUCCESS=1; break; fi
    sleep 3
  done
fi

ELAPSED=$(( TIMEOUT_SECONDS - $(remaining) ))
if (( SUCCESS == 1 )); then
  log "\n✓ PASS：插件安装并连接成功，用时约 ${ELAPSED}s（≤ ${TIMEOUT_SECONDS}s）"
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
  log "环境保留（KEEP=1）。彻底销毁（含 PVC）：$E2E_DIR/lib/hermes-env.sh down"
fi
rm -f "$AGENT_OUT"
exit "$RC"
