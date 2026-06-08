#!/usr/bin/env bash
# openclaw-env.sh — openclaw e2e 通用启动（唯一来源：manifest + 生命周期动词）
#
# 用法（执行）:
#   e2e/lib/openclaw-env.sh <up|down|pause|resume|pod|chat|health|exec|status|render> [args]
# 用法（source，供测试用例复用）:
#   source e2e/lib/openclaw-env.sh
#   openclaw_env_up; pod=$(openclaw_env_pod); ...; openclaw_env_down
#
# 配置从 e2e/.env 读，默认值见下。LLM key 仅经 k8s Secret 注入（→ env DEEPSEEK_API_KEY），
# 不落进渲染出的 YAML，也不写进配置（内置 deepseek provider 自动读 DEEPSEEK_API_KEY）。
# manifest 内嵌于本文件（render 函数），是 runbook + 测试用例的唯一来源。
#
# 公共底座（.env/KUBECONFIG 加载、_kc/_e2e_log、rollout helper、共享默认值）抽在
# lib/_common.sh，与 lib/hermes-env.sh 共用；两者复刻同一套动词。openclaw 与 hermes 的差异：
#   uid 1000(node) vs 10000 / HOME=/home/node / clawchat/openclaw 镜像 /
#   对话走 `node openclaw.mjs agent`（hermes 是 hermes chat -q） / manifest（见 render）。

# 被执行 vs 被 source：仅在被执行时开严格模式，避免污染 source 它的调用方 shell。
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then _OE_EXECUTED=1; else _OE_EXECUTED=0; fi

# 公共底座（加载 .env、导出 KUBECONFIG、设 NAMESPACE/REGISTRY/LLM_BASE_URL/MODEL、_kc/_e2e_log）
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

# ── openclaw 专属默认值（_common 已加载 .env，故 .env 仍可覆盖）──────────────
OPENCLAW_IMAGE_TAG="${OPENCLAW_IMAGE_TAG:-v2026.5.27}"
APP="${APP:-openclaw-smoke}"
# 跟 agent 对话用的会话选择器（复用同一 key = 续上下文；换 key = 开新会话）。
OPENCLAW_SESSION_KEY="${OPENCLAW_SESSION_KEY:-agent:default:smoke-test}"
_GEN_YAML="${TMPDIR:-/tmp}/${APP}.gen.yaml"

# ── 渲染 manifest（PVC + ConfigMap + Deployment；Secret 由 up 命令式建）──────
# heredoc 为展开式：$APP / $LLM_BASE_URL 等会展开。LLM key 不出现在 manifest 里 ——
# 它只经 Secret → env DEEPSEEK_API_KEY 注入，内置 deepseek provider 运行时自动读取。
openclaw_env_render() ( set -euo pipefail
  cat >"$_GEN_YAML" <<YAML
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
  openclaw.json: |
    {
      "models": {
        "providers": {
          "deepseek": {
            "baseUrl": "${LLM_BASE_URL}"
          }
        }
      }
    }
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
      securityContext: { runAsUser: 1000, runAsGroup: 1000, fsGroup: 1000 }
      # openclaw.json 必须是状态卷里的普通【可写】文件：安装会写入 base-url（install-cli 的
      # write-openclaw 直接 fs.writeFileSync），channels add 也会改它。若把 ConfigMap 用 subPath
      # 直接挂到 openclaw.json 上，该文件只读，写入会失败（EACCES/EROFS）。所以把 ConfigMap 挂到
      # /seed，再用 initContainer 拷进 PVC（整个 ~/.openclaw 才是可写卷，不要对 openclaw.json 用 subPath）。
      initContainers:
        - name: seed-config
          image: ${REGISTRY}/clawchat/openclaw:${OPENCLAW_IMAGE_TAG}
          command: ["sh", "-c"]
          args:
            - cp -n /seed/openclaw.json /home/node/.openclaw/openclaw.json 2>/dev/null || true
          volumeMounts:
            - { name: state,  mountPath: /home/node/.openclaw }
            - { name: config, mountPath: /seed }
      containers:
        - name: openclaw
          image: ${REGISTRY}/clawchat/openclaw:${OPENCLAW_IMAGE_TAG}
          # 默认 cmd 是 \`node openclaw.mjs gateway\`（要 ClawChat token）。冒烟保持闲置，
          # 用 exec 驱动 \`node openclaw.mjs agent\`。
          args: ["sleep", "infinity"]
          env:
            - { name: HOME, value: /home/node }   # 必须：openclaw 用 ~/.openclaw
            - name: DEEPSEEK_API_KEY              # 内置 deepseek provider 自动读取；baseUrl 来自配置
              valueFrom: { secretKeyRef: { name: ${APP}-llm, key: api_key } }
          volumeMounts:
            - { name: state, mountPath: /home/node/.openclaw }
          resources:
            requests: { cpu: "100m", memory: "256Mi" }
            limits:   { cpu: "1",    memory: "1Gi" }
      volumes:
        - name: state
          persistentVolumeClaim: { claimName: ${APP}-data }
        - name: config
          configMap: { name: ${APP}-config }
YAML
)

# ── 生命周期动词 ─────────────────────────────────────────────────────────
openclaw_env_up() ( set -euo pipefail
  : "${LLM_API_KEY:?请在 e2e/.env 设置 LLM_API_KEY（clawling 网关 key，sk-crawling-…）}"
  openclaw_env_render
  _kc create secret generic "${APP}-llm" \
      --from-literal=api_key="$LLM_API_KEY" \
      --dry-run=client -o yaml | _kc apply -f -
  _kc label secret "${APP}-llm" "app=${APP}" --overwrite >/dev/null
  _kc apply -f "$_GEN_YAML"
  _e2e_rollout 180s
)

openclaw_env_down() ( set -euo pipefail
  _kc delete "deploy/${APP}" "cm/${APP}-config" "secret/${APP}-llm" "pvc/${APP}-data" \
      --ignore-not-found
)

openclaw_env_pause() ( set -euo pipefail
  # 只删 PVC（清数据）；Secret/ConfigMap 故意保留，让 resume 快速恢复。
  _kc scale "deploy/${APP}" --replicas=0
  _kc delete "pvc/${APP}-data" --ignore-not-found
)

# resume 与 up 等价（重 apply 重建干净 PVC，manifest replicas:1 自然恢复副本）
openclaw_env_resume() { openclaw_env_up; }

openclaw_env_pod() ( set -euo pipefail
  local name
  name="$(_kc get pod -l "app=${APP}" --field-selector=status.phase=Running \
      -o jsonpath='{.items[0].metadata.name}')"
  [[ -n "$name" ]] || { _e2e_log "无 Running pod（app=${APP}）——先跑 openclaw-env.sh up"; exit 1; }
  printf '%s' "$name"
)

# 跟 openclaw agent 对话（走 agent loop：系统提示 / 会话 / 工具）。
# 首调偶发卡 ~2min 后报 `terminated`——插件侧流式收尾偶发问题，原样重试一次即可（见 runbook）。
openclaw_env_chat() ( set -euo pipefail
  local prompt="${1:?用法: openclaw_env_chat \"<prompt>\"}"
  local pod; pod="$(openclaw_env_pod)"
  _kc exec "$pod" -- node openclaw.mjs agent --local \
    --model "deepseek/${MODEL}" \
    --session-key "${OPENCLAW_SESSION_KEY}" \
    -m "$prompt"
)

openclaw_env_health() { openclaw_env_chat "reply with exactly: OPENCLAW-OK"; }

# 用法: openclaw_env_exec -- <cmd...>  或  openclaw_env_exec <cmd...>
openclaw_env_exec() ( set -euo pipefail
  local pod; pod="$(openclaw_env_pod)"
  [[ "${1:-}" == "--" ]] && shift
  [[ $# -gt 0 ]] || { _e2e_log "用法: openclaw_env_exec [--] <cmd...>"; exit 1; }
  _kc exec "$pod" -- "$@"
)

openclaw_env_status() { _kc get all,cm,secret,pvc -l "app=${APP}"; }

# ── CLI dispatch（仅被执行时）────────────────────────────────────────────
_oe_usage() {
  cat >&2 <<USAGE
openclaw-env.sh — openclaw e2e 通用启动
用法: $(basename "${BASH_SOURCE[0]}") <verb> [args]
  up                起环境（建 Secret + apply + 等就绪，幂等）
  down              删 deploy/cm/secret/pvc（彻底销毁）
  pause             scale 0 + 删 PVC（暂停）
  resume            = up（恢复）
  pod               打印 Running pod 名
  chat "<prompt>"   在 pod 内 node openclaw.mjs agent（走 agent loop）
  health            发自检 prompt，应回 OPENCLAW-OK
  exec -- <cmd...>  在 pod 内执行任意命令
  status            列本环境资源
  render            仅渲染 manifest 到 $_GEN_YAML（不 apply）
配置取自 e2e/.env：LLM_API_KEY(必填), NAMESPACE, OPENCLAW_IMAGE_TAG, APP,
                   OPENCLAW_SESSION_KEY, KUBECONFIG_PATH, ...
USAGE
}

_oe_main() {
  local verb="${1:-}"; [[ $# -gt 0 ]] && shift
  case "$verb" in
    up)      openclaw_env_up ;;
    down)    openclaw_env_down ;;
    pause)   openclaw_env_pause ;;
    resume)  openclaw_env_resume ;;
    pod)     openclaw_env_pod; echo ;;
    chat)    openclaw_env_chat "$@" ;;
    health)  openclaw_env_health ;;
    exec)    openclaw_env_exec "$@" ;;
    status)  openclaw_env_status ;;
    render)  openclaw_env_render; _e2e_log "rendered → $_GEN_YAML" ;;
    ""|-h|--help|help) _oe_usage ;;
    *)       _e2e_log "未知 verb: $verb"; _oe_usage; exit 2 ;;
  esac
}

if [[ "$_OE_EXECUTED" == 1 ]]; then
  set -euo pipefail
  _oe_main "$@"
fi
