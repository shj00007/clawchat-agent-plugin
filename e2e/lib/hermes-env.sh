#!/usr/bin/env bash
# hermes-env.sh — hermes e2e 通用启动（唯一来源：manifest + 生命周期动词）
#
# 用法（执行）:
#   e2e/lib/hermes-env.sh <up|down|pause|resume|pod|chat|health|exec|status|render> [args]
# 用法（source，供测试用例复用）:
#   source e2e/lib/hermes-env.sh
#   hermes_env_up; pod=$(hermes_env_pod); ...; hermes_env_down
#
# 配置从 e2e/.env 读（相对本文件定位），默认值见下。LLM key 仅经 k8s Secret 注入，不落进
# 渲染出的 YAML。manifest 内嵌于本文件（render 函数），是 runbook + 测试用例的唯一来源。
#
# 扩展位（openclaw 落地时再做，现在勿建）：把下方标了 [COMMON] 的部分（.env/KUBECONFIG 加载、
# _kc wrapper、wait helper）抽到 e2e/lib/_common.sh，与未来 e2e/lib/openclaw-env.sh 共用；
# openclaw 版复刻同一套动词，差异在 uid(1000)/HOME=/home/node/镜像/健康自检命令/manifest。

# 被执行 vs 被 source：仅在被执行时开严格模式，避免污染 source 它的调用方 shell。
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then _HE_EXECUTED=1; else _HE_EXECUTED=0; fi

# ── [COMMON] 路径与配置加载 ───────────────────────────────────────────────
_HE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_HE_E2E_DIR="$(cd "$_HE_LIB_DIR/.." && pwd)"

if [[ -f "$_HE_E2E_DIR/.env" ]]; then
  set -a; . "$_HE_E2E_DIR/.env"; set +a
fi

NAMESPACE="${NAMESPACE:-joe-clawchat-dev}"
HERMES_IMAGE_TAG="${HERMES_IMAGE_TAG:-v2026.5.27}"
APP="${APP:-hermes-agent-smoke}"
REGISTRY="${REGISTRY:-192.168.2.129:5000}"
LLM_BASE_URL="${LLM_BASE_URL:-http://api.clawling.io/v1}"
MODEL="${MODEL:-deepseek-v4-flash}"

# KUBECONFIG：展开开头的 ~ 并导出（dev 集群凭据，必须显式用）
_he_kc_path="${KUBECONFIG_PATH:-$HOME/.kube/dev.config}"
_he_kc_path="${_he_kc_path/#\~/$HOME}"
export KUBECONFIG="$_he_kc_path"

_GEN_YAML="${TMPDIR:-/tmp}/${APP}.gen.yaml"

# ── [COMMON] 小工具 ───────────────────────────────────────────────────────
_kc()     { kubectl -n "$NAMESPACE" "$@"; }
_he_log() { printf '%s\n' "$*" >&2; }

# ── 渲染 manifest（PVC + ConfigMap + Deployment；Secret 由 up 命令式建）──────
# heredoc 为展开式：$APP 等会展开；$LLM_API_KEY 必须转义为 \$LLM_API_KEY 保持字面量，
# 在容器运行时由 secretKeyRef 注入的 env 解析，绝不在生成阶段写进磁盘上的 YAML。
hermes_env_render() ( set -euo pipefail
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
  config.yaml: |
    model:
      provider: "custom"
      default: "${MODEL}"
      base_url: "${LLM_BASE_URL}"
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
      # initContainer 往 PVC seed 两样东西（整个 /opt/data 才是可写卷）：
      #   1) config.yaml：必须是可写文件（hermes 在 plugin --enable / 激活时原子改写它；
      #      ConfigMap subPath 只读 → 写入 EBUSY）。
      #   2) LLM key 写进 \$HERMES_HOME/.env：clawchat channel 跑的常驻 gateway daemon 只从
      #      .env 读 provider key、不可靠继承 Pod env，否则从 channel 发消息回 401 Invalid
      #      API key（而 hermes chat -q 正常）。见 ../hermes-agent-e2e.md 坑 3。
      initContainers:
        - name: seed-config
          image: ${REGISTRY}/clawchat/hermes-agent:${HERMES_IMAGE_TAG}
          command: ["sh", "-c"]
          args:
            - |
              cp -n /seed/config.yaml /opt/data/config.yaml 2>/dev/null || true
              [ -f /opt/data/.env ] || cp /opt/hermes/.env.example /opt/data/.env 2>/dev/null || touch /opt/data/.env
              if ! grep -q '^OPENAI_API_KEY=' /opt/data/.env; then
                printf 'OPENAI_API_KEY=%s\nOPENROUTER_API_KEY=%s\n' "\$LLM_API_KEY" "\$LLM_API_KEY" >> /opt/data/.env
              fi
          env:
            - name: LLM_API_KEY            # 从 Secret 注入；容器运行时解析，不写进 manifest
              valueFrom: { secretKeyRef: { name: ${APP}-llm, key: api_key } }
          volumeMounts:
            - { name: data,   mountPath: /opt/data }
            - { name: config, mountPath: /seed }
      containers:
        - name: hermes-agent
          image: ${REGISTRY}/clawchat/hermes-agent:${HERMES_IMAGE_TAG}
          args: ["sleep", "infinity"]
          env:
            - { name: HERMES_HOME, value: /opt/data }
            - name: OPENAI_API_KEY
              valueFrom: { secretKeyRef: { name: ${APP}-llm, key: api_key } }
            - name: OPENROUTER_API_KEY
              valueFrom: { secretKeyRef: { name: ${APP}-llm, key: api_key } }
          volumeMounts:
            - { name: data, mountPath: /opt/data }
          resources:
            requests: { cpu: "250m", memory: "256Mi" }
            limits:   { cpu: "2",    memory: "1Gi" }
      volumes:
        - name: data
          persistentVolumeClaim: { claimName: ${APP}-data }
        - name: config
          configMap: { name: ${APP}-config }
YAML
)

# ── 生命周期动词 ─────────────────────────────────────────────────────────
hermes_env_up() ( set -euo pipefail
  : "${LLM_API_KEY:?请在 e2e/.env 设置 LLM_API_KEY（clawling 网关 key，sk-crawling-…）}"
  hermes_env_render
  _kc create secret generic "${APP}-llm" \
      --from-literal=api_key="$LLM_API_KEY" \
      --dry-run=client -o yaml | _kc apply -f -
  _kc label secret "${APP}-llm" "app=${APP}" --overwrite >/dev/null
  _kc apply -f "$_GEN_YAML"
  _kc rollout status "deploy/${APP}" --timeout=180s
)

hermes_env_down() ( set -euo pipefail
  _kc delete "deploy/${APP}" "cm/${APP}-config" "secret/${APP}-llm" "pvc/${APP}-data" \
      --ignore-not-found
)

hermes_env_pause() ( set -euo pipefail
  # 只删 PVC（清数据）；Secret/ConfigMap 故意保留，让 resume 快速恢复。
  _kc scale "deploy/${APP}" --replicas=0
  _kc delete "pvc/${APP}-data" --ignore-not-found
)

# resume 与 up 等价（重 apply 重建干净 PVC，manifest replicas:1 自然恢复副本）
hermes_env_resume() { hermes_env_up; }

hermes_env_pod() ( set -euo pipefail
  local name
  name="$(_kc get pod -l "app=${APP}" --field-selector=status.phase=Running \
      -o jsonpath='{.items[0].metadata.name}')"
  [[ -n "$name" ]] || { _he_log "无 Running pod（app=${APP}）——先跑 hermes-env.sh up"; exit 1; }
  printf '%s' "$name"
)

hermes_env_chat() ( set -euo pipefail
  local prompt="${1:?用法: hermes_env_chat \"<prompt>\"}"
  local pod; pod="$(hermes_env_pod)"
  _kc exec "$pod" -- bash -lc \
    'source /opt/hermes/.venv/bin/activate; hermes chat -q "$1"' -- "$prompt"
)

hermes_env_health() { hermes_env_chat "reply with exactly: HERMES-OK"; }

# 用法: hermes_env_exec -- <cmd...>  或  hermes_env_exec <cmd...>
hermes_env_exec() ( set -euo pipefail
  local pod; pod="$(hermes_env_pod)"
  [[ "${1:-}" == "--" ]] && shift
  [[ $# -gt 0 ]] || { _he_log "用法: hermes_env_exec [--] <cmd...>"; exit 1; }
  _kc exec "$pod" -- "$@"
)

hermes_env_status() { _kc get all,cm,secret,pvc -l "app=${APP}"; }

# ── CLI dispatch（仅被执行时）────────────────────────────────────────────
_he_usage() {
  cat >&2 <<USAGE
hermes-env.sh — hermes e2e 通用启动
用法: $(basename "${BASH_SOURCE[0]}") <verb> [args]
  up                起环境（建 Secret + apply + 等就绪，幂等）
  down              删 deploy/cm/secret/pvc（彻底销毁）
  pause             scale 0 + 删 PVC（暂停）
  resume            = up（恢复）
  pod               打印 Running pod 名
  chat "<prompt>"   在 pod 内 hermes chat -q
  health            发自检 prompt，应回 HERMES-OK
  exec -- <cmd...>  在 pod 内执行任意命令
  status            列本环境资源
  render            仅渲染 manifest 到 $_GEN_YAML（不 apply）
配置取自 e2e/.env：LLM_API_KEY(必填), NAMESPACE, HERMES_IMAGE_TAG, APP, KUBECONFIG_PATH, ...
USAGE
}

_he_main() {
  local verb="${1:-}"; [[ $# -gt 0 ]] && shift
  case "$verb" in
    up)      hermes_env_up ;;
    down)    hermes_env_down ;;
    pause)   hermes_env_pause ;;
    resume)  hermes_env_resume ;;
    pod)     hermes_env_pod; echo ;;
    chat)    hermes_env_chat "$@" ;;
    health)  hermes_env_health ;;
    exec)    hermes_env_exec "$@" ;;
    status)  hermes_env_status ;;
    render)  hermes_env_render; _he_log "rendered → $_GEN_YAML" ;;
    ""|-h|--help|help) _he_usage ;;
    *)       _he_log "未知 verb: $verb"; _he_usage; exit 2 ;;
  esac
}

if [[ "$_HE_EXECUTED" == 1 ]]; then
  set -euo pipefail
  _he_main "$@"
fi
