# Hermes E2E 通用启动抽象 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 hermes e2e 环境的基础启动抽成单一可复用的 `e2e/lib/hermes-env.sh`，让 runbook 与测试用例引用它而非各自复制 manifest。

**Architecture:** 一个 Shell 库，内嵌唯一一份参数化 manifest（含「把 LLM key seed 进 `$HERMES_HOME/.env`」的坑 3 修复），暴露 `up/down/pause/resume/pod/chat/health/exec/status/render` 动词。被执行时按动词 dispatch；被 `source` 时只导出 `hermes_env_*` 函数。runbook 瘦身为调 lib，测试用例 source lib。

**Tech Stack:** Bash、kubectl、joe dev 集群（`~/.kube/dev.config`，ns `joe-clawchat-dev`）。无单测框架；验证靠 `bash -n` / `shellcheck`（若有）/ `kubectl --dry-run` / 真集群冒烟。

**前置：** 配置取自 `e2e/.env`（已存在，含真实 `LLM_API_KEY`）。所有 kubectl 走 `KUBECONFIG=~/.kube/dev.config`。

> **提交约定**：本仓库（aggregator）e2e/ + docs/ 的改动直接提交到当前 `dev` 分支。用户偏好「仅在要求时提交」——执行本计划即视为授权按各 Task 的 commit 步骤提交；若执行者不确定可先攒着最后一并提交。

---

## File Structure

- `e2e/lib/hermes-env.sh` — **新增**。唯一来源：manifest + 生命周期动词 + CLI dispatch + sourced 契约。
- `e2e/hermes-agent-e2e.md` — **重写**。保留定位/三个坑/关键坐标散文；启动/发 prompt/停止段落改为调 lib。
- `e2e/usercase/run-hermes-install-activate.sh` — **重写**。删 `write_manifest`/内联 teardown/secret/apply/rollout；source lib 调函数。
- `e2e/usercase/.hermes-agent-smoke.gen.yaml` — **删除**（manifest 改由 lib 渲染到 `/tmp`）。

---

## Task 1: 写 `e2e/lib/hermes-env.sh`（完整 lib + 静态校验）

**Files:**
- Create: `e2e/lib/hermes-env.sh`

- [ ] **Step 1: 写完整 lib 文件**

创建 `e2e/lib/hermes-env.sh`，内容如下（完整，勿留占位）：

```bash
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

: "${LLM_API_KEY:?请在 e2e/.env 设置 LLM_API_KEY（clawling 网关 key，sk-crawling-…）}"
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
  _kc scale "deploy/${APP}" --replicas=0
  _kc delete "pvc/${APP}-data" --ignore-not-found
)

# resume 与 up 等价（重 apply 重建干净 PVC，manifest replicas:1 自然恢复副本）
hermes_env_resume() { hermes_env_up; }

hermes_env_pod() ( set -euo pipefail
  _kc get pod -l "app=${APP}" --field-selector=status.phase=Running \
      -o jsonpath='{.items[0].metadata.name}'
)

hermes_env_chat() ( set -euo pipefail
  local prompt="${1:?用法: hermes_env_chat \"<prompt>\"}"
  local pod; pod="$(hermes_env_pod)"
  _kc exec "$pod" -- bash -lc \
    "source /opt/hermes/.venv/bin/activate; hermes chat -q $(printf '%q' "$prompt")"
)

hermes_env_health() { hermes_env_chat "reply with exactly: HERMES-OK"; }

# 用法: hermes_env_exec -- <cmd...>  或  hermes_env_exec <cmd...>
hermes_env_exec() ( set -euo pipefail
  local pod; pod="$(hermes_env_pod)"
  [[ "${1:-}" == "--" ]] && shift
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
```

- [ ] **Step 2: 加可执行位**

Run: `chmod +x e2e/lib/hermes-env.sh`
Expected: 无输出，退出码 0。

- [ ] **Step 3: 语法校验**

Run: `bash -n e2e/lib/hermes-env.sh && echo SYNTAX_OK`
Expected: 打印 `SYNTAX_OK`。

- [ ] **Step 4: shellcheck（若安装）**

Run: `command -v shellcheck >/dev/null && shellcheck -S warning e2e/lib/hermes-env.sh || echo "shellcheck 未装，跳过"`
Expected: 无 error 级问题（warning 可接受），或打印「跳过」。

- [ ] **Step 5: source 契约 — 只导出函数、不执行动作**

Run:
```bash
bash -c 'source e2e/lib/hermes-env.sh; for f in up down pause resume pod chat health exec status render; do declare -F "hermes_env_$f" >/dev/null || { echo "MISSING hermes_env_$f"; exit 1; }; done; echo SOURCED_OK'
```
Expected: 打印 `SOURCED_OK`（说明 source 后所有函数已定义，且未触发任何 kubectl/部署）。

- [ ] **Step 6: render + dry-run + 无明文 key**

Run:
```bash
e2e/lib/hermes-env.sh render
KUBECONFIG=~/.kube/dev.config kubectl apply -f /tmp/hermes-agent-smoke.gen.yaml --dry-run=server -n joe-clawchat-dev
grep -q 'sk-' /tmp/hermes-agent-smoke.gen.yaml && echo "FAIL: 明文 key 泄漏到 YAML" || echo "NO_PLAINTEXT_KEY_OK"
grep -q 'LLM_API_KEY' /tmp/hermes-agent-smoke.gen.yaml && echo "LITERAL_ENV_REF_OK"
```
Expected: dry-run 全部 `configured/unchanged (server dry run)`；打印 `NO_PLAINTEXT_KEY_OK` 与 `LITERAL_ENV_REF_OK`（initContainer args 里是字面量 `$LLM_API_KEY`，运行时才解析）。

- [ ] **Step 7: Commit**

```bash
git add e2e/lib/hermes-env.sh
git commit -m "feat(e2e): add shared hermes-env.sh startup lib (single-source manifest + .env key seed)"
```

---

## Task 2: 真集群冒烟验证（up / health / exec / pause / resume / down）

**Files:** 无（纯验证 Task 1 的 lib 行为）

- [ ] **Step 1: 起环境**

Run: `e2e/lib/hermes-env.sh up`
Expected: 末行 `deployment "hermes-agent-smoke" successfully rolled out`。

- [ ] **Step 2: pod 就绪**

Run: `e2e/lib/hermes-env.sh status`
Expected: pod `1/1 Running`，`RESTARTS 0`；PVC `Bound`。

- [ ] **Step 3: 健康自检接通模型**

Run: `e2e/lib/hermes-env.sh health`
Expected: 输出框里出现 `HERMES-OK`。

- [ ] **Step 4: 验证坑 3 修复 —— .env 已被 initContainer seed 了 key**

Run: `e2e/lib/hermes-env.sh exec -- bash -lc "grep -c '^OPENAI_API_KEY=' /opt/data/.env"`
Expected: 打印 `1`（说明全新 PVC 上 initContainer 自动把 provider key 写进了 `$HERMES_HOME/.env`）。

- [ ] **Step 5: pause 清掉 PVC**

Run:
```bash
e2e/lib/hermes-env.sh pause
KUBECONFIG=~/.kube/dev.config kubectl -n joe-clawchat-dev get pvc/hermes-agent-smoke-data 2>&1
```
Expected: deploy 缩到 0；`get pvc` 返回 `NotFound`。

- [ ] **Step 6: resume 重建并就绪**

Run: `e2e/lib/hermes-env.sh resume`
Expected: 重建干净 PVC 并 `successfully rolled out`。

- [ ] **Step 7: down 清干净**

Run:
```bash
e2e/lib/hermes-env.sh down
KUBECONFIG=~/.kube/dev.config kubectl -n joe-clawchat-dev get all,cm,secret,pvc -l app=hermes-agent-smoke
```
Expected: `down` 删除四件套；最后一条 `No resources found`。

- [ ] **Step 8: 无需 commit**（本 Task 仅验证，不改文件）

---

## Task 3: 重写 runbook `e2e/hermes-agent-e2e.md`

**Files:**
- Modify: `e2e/hermes-agent-e2e.md`

- [ ] **Step 1: 保留散文、替换可执行块**

保留文件现有的「定位 / 关键坐标 / 三个必须知道的坑 / 排错」散文（它们解释 *为什么* lib 是这个形状）。把下列内容删除/替换：

1. 删除「## 启动步骤 → ### 1. 准备 manifest」整段内嵌 YAML（约从 `### 1. 准备 manifest` 到该 YAML fenced block 结束）。
2. 把「### 2. apply 并等待就绪」「## 发 prompt」「## 停止 / 清理」三段里的 `kubectl ...` / `POD=$(...)` 命令块，替换为 lib 调用。

替换后「启动步骤」一节正文改为：

````markdown
## 启动步骤

环境的唯一来源是 [`lib/hermes-env.sh`](lib/hermes-env.sh)（manifest 内嵌其中，含三个坑的修复）。
先把凭据填进 `e2e/.env`（见 [`.env.example`](.env.example)）：至少 `LLM_API_KEY`（clawling 网关
key），其余 `NAMESPACE` / `HERMES_IMAGE_TAG` / `KUBECONFIG_PATH` 有默认值。然后：

```bash
e2e/lib/hermes-env.sh up        # 建 Secret + apply manifest + 等 rollout（幂等）
e2e/lib/hermes-env.sh status    # 期望 pod 1/1 Running、RESTARTS 0、PVC Bound
```

> kubectl 凭据由 lib 自动 `export KUBECONFIG`（默认 `~/.kube/dev.config`，可在 `.env` 用
> `KUBECONFIG_PATH` 覆盖）。列 registry 可用 tag：
> `curl -s http://192.168.2.129:5000/v2/clawchat/hermes-agent/tags/list`
````

「发 prompt」一节正文改为：

````markdown
## 发 prompt（核心用法）

```bash
e2e/lib/hermes-env.sh chat "你的 prompt 写这里"
e2e/lib/hermes-env.sh health          # 自检：应回 HERMES-OK
```

需要进容器排查：`e2e/lib/hermes-env.sh exec -- bash`（或 `exec -- <cmd>` 跑单条命令）。
````

「停止 / 清理」一节正文改为：

````markdown
## 停止 / 清理

这是临时环境，测完务必停掉：

```bash
e2e/lib/hermes-env.sh pause     # 暂停：scale 0 + 删 PVC（之后 resume 重建干净 PVC 恢复）
e2e/lib/hermes-env.sh resume    # 恢复（= up）
e2e/lib/hermes-env.sh down      # 彻底销毁四件套（含 PVC），集群不留痕
```

> 用了 local-path PVC：pause/down 都会删掉它（绑死节点、无保留价值）。down 后用
> `e2e/lib/hermes-env.sh status` 确认 `No resources found`。
````

「排错」一节里把裸 `kubectl logs/describe` 示例保留（排错时仍直接用 kubectl 最顺手），但在顶部加一行：
`> 下列命令需 KUBECONFIG=~/.kube/dev.config；或先 e2e/lib/hermes-env.sh exec -- <cmd> 进容器。`

「三个坑」散文保持不变（坑 3 仍准确：lib 的 initContainer 正是据此 seed `.env`）。

- [ ] **Step 2: 确认 md 不再内嵌整份 manifest**

Run: `grep -nE 'kind: Deployment|kind: PersistentVolumeClaim' e2e/hermes-agent-e2e.md || echo "NO_EMBEDDED_MANIFEST_OK"`
Expected: 打印 `NO_EMBEDDED_MANIFEST_OK`（整份 YAML 已移除；坑 3 散文里若提到 `initContainer` 字样不算 manifest）。

- [ ] **Step 3: 确认指向 lib**

Run: `grep -c 'lib/hermes-env.sh' e2e/hermes-agent-e2e.md`
Expected: ≥ 4（启动/发prompt/停止 等处均引用）。

- [ ] **Step 4: Commit**

```bash
git add e2e/hermes-agent-e2e.md
git commit -m "docs(e2e): point hermes runbook at lib/hermes-env.sh, drop embedded manifest"
```

---

## Task 4: 重写测试脚本 `run-hermes-install-activate.sh` + 删除 gen.yaml

**Files:**
- Modify: `e2e/usercase/run-hermes-install-activate.sh`
- Delete: `e2e/usercase/.hermes-agent-smoke.gen.yaml`

- [ ] **Step 1: source lib，删除自带启动逻辑**

在脚本里：

1. 在读完 `e2e/.env`、定义 `HERE`/`E2E_DIR` 之后，加：
   ```bash
   # 复用通用启动（manifest/secret/apply/teardown 的唯一来源）
   source "$E2E_DIR/lib/hermes-env.sh"
   ```
   （注意：lib 被 source 时只导出函数、不执行动作；它自身会再次 `source e2e/.env` 并设默认值，
   与脚本已读的值一致，幂等无副作用。）

2. **删除** `write_manifest() { ... }` 整个函数及其调用 `write_manifest`。
3. **删除** 脚本内联的 `teardown`、`kc create secret ...`、`kc apply -f "$MANIFEST"`、
   `kc rollout status ...` 这套「起环境」代码块，替换为：
   ```bash
   log "① 起 hermes e2e 环境（ns=$NAMESPACE, tag=$HERMES_IMAGE_TAG）"
   log "   清理上一轮残留（含 PVC）以确保全新环境..."
   hermes_env_down || true            # 幂等清理上一轮
   hermes_env_up                      # 建 Secret + apply + 等 rollout（≤180s）
   POD="$(hermes_env_pod)"
   ```
4. 把后续所有取 pod 名的地方统一用上面的 `POD`（已有 `$POD` 变量则保持）。
5. 脚本结尾/清理路径里，把原先按 `$MANIFEST` 反向删除或按名删资源的逻辑，替换为 `hermes_env_down`
   （保留脚本「激活成功后是否保留环境」的既有策略；只是删除动作改调 `hermes_env_down`）。
6. 删除不再用到的变量 `MANIFEST="$HERE/.hermes-agent-smoke.gen.yaml"`。

保留：install/activate 业务逻辑、连接码申请 curl、卡死早杀/重试轮询、`connected_check`/
`activated_check`、独占拉起 gateway、3 分钟硬超时、PASS/FAIL。

- [ ] **Step 2: 删除已废弃的生成产物**

Run: `git rm e2e/usercase/.hermes-agent-smoke.gen.yaml`
Expected: `rm 'e2e/usercase/.hermes-agent-smoke.gen.yaml'`。

- [ ] **Step 3: 语法 + 静态检查**

Run:
```bash
bash -n e2e/usercase/run-hermes-install-activate.sh && echo SYNTAX_OK
grep -q 'write_manifest' e2e/usercase/run-hermes-install-activate.sh && echo "FAIL: 仍有 write_manifest" || echo "NO_WRITE_MANIFEST_OK"
grep -q 'source .*lib/hermes-env.sh' e2e/usercase/run-hermes-install-activate.sh && echo "SOURCES_LIB_OK"
```
Expected: `SYNTAX_OK` + `NO_WRITE_MANIFEST_OK` + `SOURCES_LIB_OK`。

- [ ] **Step 4: 端到端跑一次测试用例（消耗一个连接码，≤3min）**

Run: `cd e2e/usercase && ./run-hermes-install-activate.sh`
Expected: 末尾 `✓ PASS：插件安装并连接成功，用时约 Ns（≤ 180s）`，退出码 0。
（若因连接码/JWT 环境问题失败，按脚本 diagnostics 排查；本步是真集群验证，确认重构未破坏流程。）

- [ ] **Step 5: 收尾清理环境**

Run: `e2e/lib/hermes-env.sh down`
Expected: 四件套删除。

- [ ] **Step 6: Commit**

```bash
git add e2e/usercase/run-hermes-install-activate.sh
git commit -m "refactor(e2e): run-hermes-install-activate.sh reuses lib/hermes-env.sh; drop duplicated manifest"
```

---

## Task 5: 计划自审 + 文档收尾

- [ ] **Step 1: 确认 README 索引仍准确**

Run: `grep -nE 'lib/|hermes-env|hermes-agent-e2e' e2e/README.md e2e/usercase/README.md`
检查：若 README 里有「manifest 内嵌于 runbook」之类描述已过时，则更新为「启动逻辑在
`e2e/lib/hermes-env.sh`」。若无相关描述则跳过。

- [ ] **Step 2: 若 Step 1 有改动则 commit**

```bash
git add e2e/README.md e2e/usercase/README.md
git commit -m "docs(e2e): note shared lib/hermes-env.sh in README index"
```

---

## Self-Review（写计划者已执行）

- **Spec 覆盖**：lib（Task 1）含 spec 的全部动词 + 配置 + sourced 契约 + manifest（坑 3 修复）+ 扩展位注释；runbook 重写（Task 3）；测试重写（Task 4）；gen.yaml 删除（Task 4 Step 2）；验证项（Task 2）对应 spec「验证」一节。无遗漏。
- **占位符扫描**：无 TBD/TODO；所有代码与命令均为实际内容。
- **类型/命名一致**：动词 ↔ `hermes_env_<verb>` 函数一一对应（up/down/pause/resume/pod/chat/health/exec/status/render），dispatch case 与函数名一致；资源名统一 `${APP}` / `${APP}-config` / `${APP}-llm` / `${APP}-data`，down 与 manifest 命名匹配。
- **已知缺口**：测试仍不做 channel 真往返断言（spec 备注，本次非范围）。
