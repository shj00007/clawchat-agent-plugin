#!/usr/bin/env bash
# _common.sh — e2e 启动 lib 的公共底座（被 hermes-env.sh / openclaw-env.sh source）
#
# 只放**跨两个 env 共用**的东西：e2e/.env + KUBECONFIG 加载、共享默认值
# (NAMESPACE/REGISTRY/LLM_BASE_URL/MODEL)、`_kc` wrapper、`_e2e_log`、rollout 等待 helper。
# 各 env 的「同一套动词」(up/down/pause/resume/pod/chat/health/exec/status/render) 在各自的
# *-env.sh 里**复刻**，差异在 uid / HOME / 镜像 / 健康自检命令 / manifest。
#
# 本文件只应被 source（hermes-env.sh / openclaw-env.sh 顶部），不单独执行。
# env 专属的 APP / 镜像 tag / _GEN_YAML 由各 *-env.sh 自己在 source 之后设置（此时 .env 已加载，
# 故 .env 仍可覆盖它们）。

# 幂等：防重复 source（if/return 写法对 set -e 安全）
if [[ -n "${_E2E_COMMON_LOADED:-}" ]]; then return 0; fi
_E2E_COMMON_LOADED=1

# ── 路径（相对本文件定位，与「谁 source 它」无关）────────────────────────────
_E2E_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_E2E_DIR="$(cd "$_E2E_LIB_DIR/.." && pwd)"

# ── 读 e2e/.env（set -a 让其中变量导出；.env 优先于下面的默认值）──────────────
if [[ -f "$_E2E_DIR/.env" ]]; then
  set -a; . "$_E2E_DIR/.env"; set +a
fi

# ── 共享默认值（env 专属的 APP / 镜像 tag 不在此）────────────────────────────
NAMESPACE="${NAMESPACE:-joe-clawchat-dev}"
REGISTRY="${REGISTRY:-192.168.2.129:5000}"
LLM_BASE_URL="${LLM_BASE_URL:-http://api.clawling.io/v1}"
MODEL="${MODEL:-deepseek-v4-flash}"

# ── KUBECONFIG：展开开头的 ~ 并导出（dev 集群凭据，必须显式用）──────────────
_e2e_kc_path="${KUBECONFIG_PATH:-$HOME/.kube/dev.config}"
_e2e_kc_path="${_e2e_kc_path/#\~/$HOME}"
export KUBECONFIG="$_e2e_kc_path"

# ── 小工具 ─────────────────────────────────────────────────────────────────
_kc()        { kubectl -n "$NAMESPACE" "$@"; }
_e2e_log()   { printf '%s\n' "$*" >&2; }
# 等 Deployment rollout（默认 180s）。用法: _e2e_rollout [timeout]
_e2e_rollout() { _kc rollout status "deploy/${APP}" --timeout="${1:-180s}"; }
