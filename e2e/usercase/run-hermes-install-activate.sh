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
MANIFEST="$HERE/.hermes-agent-smoke.gen.yaml"

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

# ── 1. 起 hermes e2e 环境 ─────────────────────────────────────────────────
# manifest 与 ../hermes-agent-e2e.md 一致：local-path PVC + securityContext(10000)
# + sleep infinity。LLM 走内部 clawling 网关；此处不放 clawchat platform（靠激活写入）。
write_manifest() {
  cat >"$MANIFEST" <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: ${APP}-data, namespace: ${NAMESPACE}, labels: { app: ${APP} } }
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: local-path
  resources: { requests: { storage: 2Gi } }
---
apiVersion: v1
kind: ConfigMap
metadata: { name: ${APP}-config, namespace: ${NAMESPACE}, labels: { app: ${APP} } }
data:
  config.yaml: |
    model:
      provider: "custom"
      default: "deepseek-v4-flash"
      base_url: "http://api.clawling.io/v1"
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: ${APP}, namespace: ${NAMESPACE}, labels: { app: ${APP} } }
spec:
  replicas: 1
  selector: { matchLabels: { app: ${APP} } }
  template:
    metadata: { labels: { app: ${APP} } }
    spec:
      securityContext: { runAsUser: 10000, runAsGroup: 10000, fsGroup: 10000 }
      # config.yaml must be a normal WRITABLE file in the PVC: hermes rewrites it
      # on plugin --enable and on activation (atomic os.replace). Bind-mounting it
      # as a ConfigMap subPath makes those writes fail with EBUSY ("Device or
      # resource busy"), so we seed it into the PVC via an initContainer instead.
      initContainers:
        - name: seed-config
          image: 192.168.2.129:5000/clawchat/hermes-agent:${HERMES_IMAGE_TAG}
          command: ["sh", "-c", "cp -n /seed/config.yaml /opt/data/config.yaml 2>/dev/null || true"]
          volumeMounts:
            - { name: data,   mountPath: /opt/data }
            - { name: config, mountPath: /seed }
      containers:
        - name: hermes-agent
          image: 192.168.2.129:5000/clawchat/hermes-agent:${HERMES_IMAGE_TAG}
          args: ["sleep", "infinity"]
          env:
            - { name: HERMES_HOME, value: /opt/data }
            - name: OPENAI_API_KEY        # custom/clawling 网关 provider 从这里读 key
              valueFrom: { secretKeyRef: { name: ${APP}-llm, key: api_key } }
            - name: OPENROUTER_API_KEY    # 部分回退路径会读它，塞同一个 key
              valueFrom: { secretKeyRef: { name: ${APP}-llm, key: api_key } }
          volumeMounts:
            - { name: data,   mountPath: /opt/data }
          resources:
            requests: { cpu: "250m", memory: "256Mi" }
            limits:   { cpu: "2",    memory: "1Gi" }   # npx/git/python + the poll loop share this core; 2 avoids starving the agent turn
      volumes:
        - name: data
          persistentVolumeClaim: { claimName: ${APP}-data }
        - name: config
          configMap: { name: ${APP}-config }
YAML
}

log "① 起 hermes e2e 环境（ns=$NAMESPACE, tag=$HERMES_IMAGE_TAG）"
write_manifest
# LLM key 走 Secret（不落进磁盘上的 manifest）。
kc create secret generic "${APP}-llm" --from-literal=api_key="$LLM_API_KEY" \
   --dry-run=client -o yaml | kubectl -n "$NAMESPACE" apply -f - >/dev/null \
   || fail "创建 LLM Secret 失败"
kubectl apply -f "$MANIFEST" >/dev/null
kc rollout status deploy/"$APP" --timeout=180s || fail "环境未就绪（镜像拉取/调度失败？）"
POD="$(running_pod)"; [[ -n "$POD" ]] || fail "找不到 Running 的 pod"
log "   pod=$POD Running"

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
# agent turn 预留出 ~25s 给随后的「拉起 gateway + 轮询握手」。
AGENT_BUDGET=$(( $(remaining) - 25 )); (( AGENT_BUDGET < 30 )) && AGENT_BUDGET=$(remaining)
log "   发 prompt 驱动 agent 安装+激活（agent 预算 ${AGENT_BUDGET}s，总剩余 $(remaining)s）"
# hermes chat 一次性 agent turn：模型按 install-dev.md 跑 npx 安装 + `hermes clawchat activate <code>`。
# 关键：让 agent turn 跑完再去碰 gateway。激活会先写 .env(CLAWCHAT_TOKEN) 再写 sqlite，
# 若在 agent turn 进行中并发 `hermes gateway restart`，会打断激活（sqlite 没落库）并拖垮
# 这台 1-2 核 pod 上的 agent。改成「先等 agent turn 结束，再起 gateway + 轮询」纯串行。
# NOTE: `timeout` execs an external binary, so it must wrap `kubectl` directly —
# NOT the `kc` shell function (`timeout kc …` fails instantly with "No such file
# or directory", so the agent turn never runs: empty output, no activation).
( timeout "$AGENT_BUDGET" kubectl -n "$NAMESPACE" exec "$POD" -- bash -lc \
    "source /opt/hermes/.venv/bin/activate 2>/dev/null; hermes chat -q $(printf '%q' "$PROMPT")" \
    >"$AGENT_OUT" 2>&1 ) &
AGENT_PID=$!

# ── 4. 等 agent turn 结束 → 拉起 gateway → 轮询「连接上」──────────────────────
# 激活本身会调度一次 detached `hermes gateway restart`；这里在 agent 跑完后再显式
# 兜底起一个（幂等），确保 WS 真正建立且日志可被 grep。
SUCCESS=0
log "④ 等 agent turn 结束（不并发干扰激活）..."
wait "$AGENT_PID" 2>/dev/null
log "   agent turn 结束 → 兜底拉起 gateway → 轮询 WebSocket 握手（总剩余 $(remaining)s）"
kc exec "$POD" -- bash -lc \
  'source /opt/hermes/.venv/bin/activate 2>/dev/null; \
   pgrep -f "hermes gateway" >/dev/null || nohup hermes gateway restart >>/opt/data/gateway.log 2>&1 &' \
  >/dev/null 2>&1 || true
while (( $(remaining) > 0 )); do
  # 连接成功信号：日志 handshake_ok 或 connections.state=ready。
  if connected_check; then SUCCESS=1; break; fi
  sleep 3
done

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
  log "清理环境（KEEP=0）"
  kubectl delete -f "$MANIFEST" >/dev/null 2>&1 || true
  kc delete secret "${APP}-llm" >/dev/null 2>&1 || true   # Secret 单独建的，单独删
else
  log "环境保留（KEEP=1）。彻底销毁：kubectl delete -f '$MANIFEST'"
fi
rm -f "$AGENT_OUT"
exit "$RC"
