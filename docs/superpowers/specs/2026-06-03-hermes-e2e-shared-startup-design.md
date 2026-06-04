# Hermes E2E 通用启动抽象 — 设计

- 日期：2026-06-03
- 范围仓库：`clawchat-agent-plugin`（aggregator，e2e 资料所在）
- 状态：已与用户确认设计，待写实现计划

## 背景与问题

`e2e/hermes-agent-e2e.md`（runbook）内嵌一整份启动 manifest，`e2e/usercase/run-hermes-install-activate.sh`
又用 `write_manifest()` heredoc **复制了同一份 manifest**，并各自实现 bringup / teardown / 等待 / 发
prompt。后果：

- manifest 出现在两处，任何修复（如最近的「gateway 不继承 Pod env → 从 channel 发消息报
  `401 Invalid API key`」修复，需把 LLM key seed 进 `$HERMES_HOME/.env`）都要改两遍，易漏。
- 以后还会有更多测试用例，每个都重复一遍启动逻辑。

## 目标

把 **hermes e2e 环境的基础启动** 抽成单一可复用来源：runbook 与所有测试用例都引用它，而不是各自复制。
本次只做 hermes，但接口/目录结构要为 openclaw 预留平滑接入位。

非目标（YAGNI）：现在不抽 openclaw；不建跨 adapter 的 `_common.sh`（留注释标记，待 openclaw 落地再抽）。

## 方案：`e2e/lib/hermes-env.sh`（Shell 库 + 内嵌 manifest）

### 文件布局

```
e2e/
  lib/hermes-env.sh         # 新增:唯一来源 — manifest(heredoc) + 生命周期动词
  hermes-agent-e2e.md       # 重写:保留定位/三个坑/关键坐标,启动步骤改为调 lib
  usercase/
    run-hermes-install-activate.sh  # 重写:source lib,删掉自带 write_manifest/teardown/secret/apply
    .hermes-agent-smoke.gen.yaml    # 删除(改由 lib 渲染到 /tmp)
```

### 配置（全部从 `e2e/.env` 读，带默认值）

lib 在最早期 `source` `e2e/.env`（相对自身路径定位），随后：

| 变量 | 默认 | 说明 |
|---|---|---|
| `LLM_API_KEY` | —（必填，缺则报错退出） | clawling 网关 key，建 Secret 用 |
| `NAMESPACE` | `joe-clawchat-dev` | |
| `HERMES_IMAGE_TAG` | `v2026.5.27` | |
| `KUBECONFIG_PATH` | `~/.kube/dev.config` | 展开 `~` 后导出为 `KUBECONFIG` |
| `APP` | `hermes-agent-smoke` | 资源名前缀 / app label，留作未来并行环境覆盖 |
| `REGISTRY` | `192.168.2.129:5000` | 镜像 registry |
| `LLM_BASE_URL` | `http://api.clawling.io/v1` | 写进 config.yaml |
| `MODEL` | `deepseek-v4-flash` | 写进 config.yaml |

效果：runbook 手动用 与 测试用例 共用同一份配置来源；runbook 不再让用户往 YAML 里贴 key，改为填 `e2e/.env`。

### 动词接口（`hermes-env.sh <verb> [args]`）

| verb | 行为 | 对应 runbook 段落 |
|---|---|---|
| `up` | 建/更新 Secret（`--from-literal=api_key=$LLM_API_KEY`）→ apply manifest（PVC+CM+Deploy）→ 等 rollout ready。幂等。 | 启动步骤 |
| `down` | 按 `-l app=$APP` 删 deploy/cm/secret/pvc | 彻底销毁(B) |
| `pause` | scale deploy 到 0 + 删 PVC | 暂停(A) |
| `resume` | 等价于 `up`（重 apply 重建干净 PVC，manifest `replicas:1` 自然恢复副本）+ 等就绪。语义上与 `up` 重叠，仅为对齐 runbook「暂停/恢复」叙述而保留；实现上 `hermes_env_resume` 直接复用 `hermes_env_up`。 | 恢复(A) |
| `pod` | 打印 Running pod 名（`--field-selector=status.phase=Running`） | — |
| `chat "<prompt>"` | 在 pod 内 `source .venv && hermes chat -q "<prompt>"` | 发 prompt |
| `health` | `chat "reply with exactly: HERMES-OK"` | 健康自检 |
| `exec -- <cmd...>` | 在 pod 内执行任意命令（逃生口） | 排错 |
| `status` | `kubectl get all,cm,secret,pvc -l app=$APP` | 排错 |

所有 kubectl 经统一 wrapper（注入 `-n $NAMESPACE`，KUBECONFIG 已导出）。

### 内嵌 manifest（唯一来源）

heredoc 内联在 lib 中，由上述配置变量参数化。等价于当前修好后的那份：

- `securityContext: runAsUser/Group/fsGroup = 10000`（坑 1）
- local-path PVC（跨重启留存，pause/down 时清掉）
- ConfigMap 提供 `config.yaml`（`provider: custom` + `base_url` + `model`，无内联 api_key）
- **initContainer 同时做两件事**：`cp -n` 把 config.yaml 拷进 PVC；并把
  `OPENAI_API_KEY`/`OPENROUTER_API_KEY`（从 Secret 注入的 `LLM_API_KEY` env）追加进
  `$HERMES_HOME/.env`（不存在才追加，幂等）——**这是坑 3 的修复**，让 clawchat channel 跑的常驻
  gateway daemon 也能拿到 provider key。
- 主容器 `args: ["sleep","infinity"]`，env 注入 `OPENAI_API_KEY`/`OPENROUTER_API_KEY`（便于裸 `chat -q`）。
- key 仅经 Secret + `secretKeyRef`，渲染出的 YAML 不含明文。

`up`/`resume` 把渲染结果写到 `${TMPDIR:-/tmp}/$APP.gen.yaml` 再 `kubectl apply -f`，便于按文件清理。

### 被 `source` 时的契约

lib 用 `[[ "${BASH_SOURCE[0]}" != "$0" ]]` 判断是否被 source：

- **被执行**（`hermes-env.sh up`）：解析 `$1` 动词并 dispatch。
- **被 source**：只定义并导出函数（`hermes_env_up` / `hermes_env_down` / `hermes_env_pause` /
  `hermes_env_resume` / `hermes_env_pod` / `hermes_env_chat` / `hermes_env_health` / `hermes_env_exec` /
  `hermes_env_status`），不自动执行任何动作。每个动词对应一个同名函数，CLI dispatch 只是薄封装。

测试用例：`source "$HERE/../lib/hermes-env.sh"` → 调 `hermes_env_up` → 跑自己的 install/activate 业务
逻辑（轮询、起 gateway、PASS/FAIL 全部保留）→ `hermes_env_down`。pod 名经 `hermes_env_pod` 取。

### runbook 重写范围

`hermes-agent-e2e.md`：保留「定位 / 三个坑 / 关键坐标」散文（解释 *为什么* lib 是这个形状，价值高）。
把「准备 manifest（整份 YAML）/ apply 等待 / 发 prompt / 停止清理」等可执行块替换为 lib 调用
（`e2e/lib/hermes-env.sh up|chat|health|pause|down`）。manifest 不再粘贴，改为指向 lib。

### 测试重写范围

`run-hermes-install-activate.sh`：删除 `write_manifest()`、内联 `teardown`、secret 创建、apply、rollout
等待；改为 `source` lib 并调 `hermes_env_up`（建 secret + apply + 等就绪）/ `hermes_env_down`。保留全部
install/activate 业务逻辑、卡死早杀/重试轮询、gateway 独占拉起、连接/激活检查、3 分钟硬超时。

### 扩展位（不现在建）

- 命名 `hermes-env.sh`（非 `e2e-env.sh`）。未来 `openclaw-env.sh` 复刻同一套动词接口
  （up/down/pause/resume/pod/chat），差异在 uid(1000)/`HOME=/home/node`/镜像/健康自检命令/manifest。
- 真正共用的部分（`.env`/KUBECONFIG 加载、kubectl wrapper、wait helper）等 openclaw 落地时再抽到
  `e2e/lib/_common.sh`；本次仅在 lib 顶部留注释标记该接缝。

## 验证

- `hermes-env.sh up && hermes-env.sh health` → 返回 `HERMES-OK`，pod `1/1 Running`、`RESTARTS 0`。
- 干净环境（全新 PVC）下 initContainer 自动 seed `.env`：
  `hermes-env.sh exec -- bash -lc "grep -c '^OPENAI_API_KEY=' /opt/data/.env"` == 1。
- 渲染产物不含明文 key（`grep` 渲染出的 gen.yaml 无 `sk-`）。
- `run-hermes-install-activate.sh` 仍能跑通（install+activate≤3min，PASS）。
- `pause` 后 PVC 被删、`resume` 重建并就绪。

## 备注（已知缺口，非本次范围）

测试用例目前只验「WebSocket 连接成功」(`connected_check`，用 `CLAWCHAT_TOKEN`，与 LLM key 无关) +
agent turn 走 `hermes chat -q`(继承 Pod env)，**从不经 channel 真正发一条消息做 LLM 往返**，所以这类
401 bug 它捕捉不到。本设计通过 initContainer seed `.env` 修复了环境；「让测试真正做一次 channel 往返
断言」是后续可选增强，本次不做。
