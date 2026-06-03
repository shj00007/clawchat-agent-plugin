# OpenClaw Agent E2E 环境启动（临时 / 用完即弃）

一种可复现的方式，在 **joe 的测试集群**里快速起一个 `clawchat/openclaw` 容器，
配好一个真实 LLM provider，然后通过命令直接发 prompt。**本文提供的是「调试 / 跑测试用例」
所需的环境启动方式** —— 起好这个真实 agent 环境后，可在其上调试 openclaw 插件、验证 agent
行为或执行具体测试用例。

> **定位**：临时调试 / 测试环境。状态目录（`/home/node/.openclaw`）挂 **`local-path` PVC** —— 数据落在节点本地盘，
> Pod 重启/重建仍在；但这仍是用完即弃的环境，停止时连 PVC 一并清掉，集群里不留痕迹。

当我（Claude）被告知「按这个方式起一个 openclaw agent」时，直接照本文执行即可。
hermes 版见 [`hermes-agent-e2e.md`](hermes-agent-e2e.md)。

---

## 关键坐标

| 项 | 值 |
|---|---|
| kubeconfig | **`~/.kube/dev.config`**（dev 集群凭据 / token，**必须显式使用**） |
| namespace | `joe-clawchat-dev` |
| 镜像 | `192.168.2.129:5000/clawchat/openclaw:<tag>`（最新见 registry，曾用 `v2026.5.27`） |
| 镜像 registry | `192.168.2.129:5000`（insecure，dev overlay 已信任，集群可直接拉） |
| LLM 网关 | `http://api.clawling.io/v1`（内部 OpenAI 兼容；key 形如 `sk-crawling-…`） |
| 模型 id | `deepseek-v4-flash`（推理模型）/ `deepseek-v4-pro` / `kimi-k2.6`（查 `/v1/models`） |
| 运行用户 | `node`，uid/gid = **1000** |

> **⚠️ kubectl 凭据：本文所有 `kubectl` 命令都必须走 dev 集群的 `~/.kube/dev.config` token。**
> 默认 kubeconfig 不一定指向这个 dev 集群，不要依赖它。开始前先在当前 shell 执行一次：
> ```bash
> export KUBECONFIG=~/.kube/dev.config
> ```
> 下文命令默认你已 export；若不想改环境，则给每条 kubectl 前缀
> `KUBECONFIG=~/.kube/dev.config kubectl …`。

> 列 registry 里可用 tag：
> `curl -s http://192.168.2.129:5000/v2/clawchat/openclaw/tags/list`

---

## OpenClaw 与 hermes 的关键差异

| 维度 | OpenClaw | hermes（对照） |
|---|---|---|
| **跟 agent 对话** | `node openclaw.mjs agent --local --session-key … -m "..."`（走 agent loop） | `hermes chat -q "..."`（本身即 agent） |
| 裸 LLM 透传（仅自检） | `node openclaw.mjs infer model run --local --model … --prompt "..."`（**不走 agent**） | hermes 无对应裸透传命令 |
| LLM 接法 | 覆盖**内置 `deepseek` provider** 的 `baseUrl`(配置) + `DEEPSEEK_API_KEY`(env) | config.yaml `provider: custom` + `OPENAI_API_KEY` |
| 运行用户 | uid **1000**（node） | uid 10000 |
| 默认 cmd | `node openclaw.mjs gateway`（要 ClawChat token） | `hermes`（等 TTY） |
| 状态目录 | `/home/node/.openclaw` | `/opt/data` |

两个要点：

1. **密钥只进 Secret，不落配置。** OpenClaw 内置 `deepseek` provider 会自动读环境变量
   `DEEPSEEK_API_KEY`，所以配置里只需覆盖非敏感的 `baseUrl`，key 走 Secret → env。
2. **必须覆盖默认 cmd。** 镜像默认 `node openclaw.mjs gateway` 需要 ClawChat token，
   冒烟阶段没有，会起不来；用 `args: ["sleep","infinity"]` 让 Pod 闲置，再用 `exec` 跑
   `infer model run`。
3. **必须设 `HOME=/home/node`** 且 `securityContext` 用 1000，否则 `~/.openclaw` 路径/写权限不对。

> `deepseek-v4-flash` 是推理模型：会先吐一段 `reasoning_content` 再出正文，所以
> openclaw `infer model run` 单次本就慢（几十秒级），且**首调偶发卡 ~2min 后报
> `No text output returned ... terminated`**——这是插件侧流式收尾的偶发问题，不是配置错，
> **原样重试一次**通常即过（已复现：同一条命令首调 terminated、二调成功）。要快速排除
> 「是不是网关/模型挂了」，用下方的直连 `curl`（非流式、秒回）。
> 注意模型可能自报为 "DeepSeek-V3/R1"（自我认知幻觉），实际走的模型以命令输出的
> `provider: deepseek / model: deepseek-v4-flash` 为准。

---

## 启动步骤

> **⏱ 提速要点（先读，能省几分钟）：**
> 1. **先复用、别重建。** 这套三件套（Secret/ConfigMap/Deployment）经常已经在集群里，
>    上一次只是用「方案 A」`scale --replicas=0` 暂停了。**走第 0 步检查**，命中就一条
>    `scale --replicas=1`（秒级）搞定，跳过 apply。
> 2. **健康检查先用直连 `curl`，别先用 openclaw `infer`/`agent`。** 二者都走推理模型
>    + 流式，单次几十秒起步，且**首调偶发卡 ~2min 后报 `terminated`**；直连
>    `/chat/completions`（非流式）通常 1～2s 返回，最快确认「网关+key+模型」是活的，
>    也能把「网关问题」和「openclaw 插件问题」一刀切开。见 [跟 openclaw 对话](#跟-openclaw-对话核心用法)。
> 3. **想测 agent 行为，用 `agent` 不是 `infer`。** `infer model run` 只是把 prompt
>    裸透传给 LLM（无系统提示/会话/工具），不代表 openclaw agent 的真实行为。

### 0. 先检查是否已存在（命中可秒级恢复）

```bash
kubectl -n joe-clawchat-dev get deploy,cm,secret -l app=openclaw-smoke 2>/dev/null
# Secret 没带 label，单独看一眼：
kubectl -n joe-clawchat-dev get secret openclaw-smoke-llm 2>/dev/null
```

- **Deployment 存在、`READY 0/0`** → 是被暂停了。注意暂停时 PVC 已被删（见「停止/清理 A」），
  恢复要先把 manifest 重新 apply（幂等重建干净 PVC），再拉副本：
  ```bash
  kubectl apply -f openclaw-smoke.yaml      # 重建 PVC（及补齐其它资源），幂等
  kubectl -n joe-clawchat-dev scale deploy/openclaw-smoke --replicas=1
  kubectl -n joe-clawchat-dev rollout status deploy/openclaw-smoke --timeout=120s
  ```
  > Secret/ConfigMap 一并保留，无需重做。想复用旧 key：
  > `kubectl -n joe-clawchat-dev get secret openclaw-smoke-llm -o jsonpath='{.data.api_key}' | base64 -d`
- **什么都没有** → 从下面第 1 步全新创建。

### 1. 准备 manifest

存成 `openclaw-smoke.yaml`（把 `<LLM_KEY>` 换成真实 key，必要时改 `<TAG>` / 模型 id）：

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: openclaw-smoke-data
  namespace: joe-clawchat-dev
  labels:
    app: openclaw-smoke
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: local-path        # 节点本地盘动态供给（local-path-provisioner）
  resources:
    requests:
      storage: 2Gi
---
apiVersion: v1
kind: Secret
metadata:
  name: openclaw-smoke-llm
  namespace: joe-clawchat-dev
type: Opaque
stringData:
  api_key: "<LLM_KEY>"            # 形如 sk-crawling-…
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: openclaw-smoke-config
  namespace: joe-clawchat-dev
data:
  openclaw.json: |
    {
      "models": {
        "providers": {
          "deepseek": {
            "baseUrl": "http://api.clawling.io/v1"
          }
        }
      }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: openclaw-smoke
  namespace: joe-clawchat-dev
  labels:
    app: openclaw-smoke
spec:
  replicas: 1
  selector:
    matchLabels:
      app: openclaw-smoke
  template:
    metadata:
      labels:
        app: openclaw-smoke
    spec:
      securityContext:          # node 用户 uid/gid=1000；fsGroup 让数据卷(PVC)可写
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
      containers:
        - name: openclaw
          image: 192.168.2.129:5000/clawchat/openclaw:v2026.5.27
          # 默认 cmd 是 `node openclaw.mjs gateway`（要 ClawChat token）。
          # 冒烟保持闲置，用 exec 驱动 `infer model run`。
          args: ["sleep", "infinity"]
          env:
            - name: HOME                  # 必须：openclaw 用 ~/.openclaw
              value: /home/node
            - name: DEEPSEEK_API_KEY      # 内置 deepseek provider 自动读取；baseUrl 来自配置
              valueFrom:
                secretKeyRef:
                  name: openclaw-smoke-llm
                  key: api_key
          volumeMounts:
            - name: state
              mountPath: /home/node/.openclaw
            - name: config
              mountPath: /home/node/.openclaw/openclaw.json
              subPath: openclaw.json
          resources:
            requests:
              cpu: "100m"
              memory: "256Mi"
            limits:
              cpu: "1"
              memory: "1Gi"
      volumes:
        - name: state
          persistentVolumeClaim:          # local-path PVC，跨重启留存；停止时记得清掉（见「停止/清理」）
            claimName: openclaw-smoke-data
        - name: config
          configMap:
            name: openclaw-smoke-config
```

### 2. apply 并等待就绪

```bash
kubectl apply -f openclaw-smoke.yaml
kubectl -n joe-clawchat-dev rollout status deploy/openclaw-smoke --timeout=180s
kubectl -n joe-clawchat-dev get pods -l app=openclaw-smoke
```

期望：Pod `1/1 Running`，`RESTARTS 0`。

---

## 跟 openclaw 对话（核心用法）

要**跟 openclaw agent 对话**（走 agent loop：系统提示、会话状态、工具语义），用
`agent` 子命令。**必须**指定一个会话选择器（`--session-key` / `--session-id` /
`--to <E.164>` / `--agent`），否则会报 `Pass --to … to choose a session`：

```bash
POD=$(kubectl -n joe-clawchat-dev get pod -l app=openclaw-smoke \
        --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')

kubectl -n joe-clawchat-dev exec "$POD" -- node openclaw.mjs agent --local \
  --model deepseek/deepseek-v4-flash \
  --session-key agent:default:smoke-test \
  -m "你的话写这里"
```

- **多轮对话**：复用同一个 `--session-key`，agent 会记住上下文；换一个 key 就是开新会话。
- 交互式 TUI：`kubectl -n joe-clawchat-dev exec -it "$POD" -- node openclaw.mjs chat`（全屏终端 UI）。
- **首调卡住/报 `terminated` → 原样重试一次**（见上文模型说明），别去改配置。

> ⚠️ **`infer model run` 不是「跟 openclaw 对话」。** 它只是把 prompt **裸透传给 LLM
> provider**（单轮、无系统提示 / 无会话 / 无工具），openclaw 在这里只是个壳。它适合当
> 「provider 接线通不通」的健康自检，**不要**拿它当 agent 行为的 e2e —— 真正测 agent 用上面的
> `agent` 命令。

### 健康自检（先快后全）

**① 快路径：直连网关（非流式，~1～2s）。** 最快确认「网关 + key + 模型」是活的，
也能把网关问题和 openclaw 插件问题切开——这是首选的「是不是活着」检查：

```bash
KEY=$(kubectl -n joe-clawchat-dev get secret openclaw-smoke-llm -o jsonpath='{.data.api_key}' | base64 -d)
kubectl -n joe-clawchat-dev exec "$POD" -- sh -c "curl -s -m 30 http://api.clawling.io/v1/chat/completions \
  -H \"Authorization: Bearer $KEY\" -H 'Content-Type: application/json' \
  -d '{\"model\":\"deepseek-v4-flash\",\"messages\":[{\"role\":\"user\",\"content\":\"reply with exactly: OPENCLAW-OK\"}],\"max_tokens\":2048}'"
# 期望：choices[0].message.content == "OPENCLAW-OK"（前面会有 reasoning_content，正常）
```

**② 中路径：provider 接线（裸 LLM 透传，非 agent）。** `infer model run` 验证
openclaw↔provider 接线通不通，但**不走 agent loop**（慢；首调失败就重试一次）：

```bash
kubectl -n joe-clawchat-dev exec "$POD" -- node openclaw.mjs infer model run --local \
  --model deepseek/deepseek-v4-flash --prompt "reply with exactly: OPENCLAW-OK"
# 期望末行：OPENCLAW-OK
```

**③ 全路径：agent loop（真正的「跟 openclaw 对话」）。** 跑一轮真实 agent（系统提示 /
会话 / 工具）：

```bash
kubectl -n joe-clawchat-dev exec "$POD" -- node openclaw.mjs agent --local \
  --model deepseek/deepseek-v4-flash --session-key agent:default:smoke-test \
  -m "reply with exactly: OPENCLAW-OK"
# 期望：回复正文含 OPENCLAW-OK
```

---

## 排错

```bash
kubectl -n joe-clawchat-dev logs -l app=openclaw-smoke --tail=60
kubectl -n joe-clawchat-dev logs <pod> --previous
kubectl -n joe-clawchat-dev describe pod -l app=openclaw-smoke | sed -n '/Events:/,$p'

# 容器内确认 provider 配置生效 / 列模型
kubectl -n joe-clawchat-dev exec <pod> -- node openclaw.mjs config get models.providers.deepseek.baseUrl
kubectl -n joe-clawchat-dev exec <pod> -- node openclaw.mjs infer model providers

# 直接验证网关/模型可用性
curl -s http://api.clawling.io/v1/models -H "Authorization: Bearer <LLM_KEY>"
```

- 权限 / `~/.openclaw` 报错 → 漏了 `HOME=/home/node` 或 `securityContext`（uid/gid/fsGroup=1000）。
- Pod 起不来且日志在等 token → 漏了 `args: ["sleep","infinity"]`，跑成了默认 `gateway`。
- `infer` 卡 ~2min 后 `No text output returned ... terminated`，但直连 `curl` 正常 →
  插件侧流式收尾偶发问题，**不是配置错；原样重试一次**即可（已复现首调失败、二调成功）。

---

## 停止 / 清理

这是临时冒烟环境，**测完务必停掉**。按需选其一：

### A. 临时暂停（保留配置，之后能快速恢复）

把副本缩到 0：Pod 销毁，但 Deployment / ConfigMap / Secret 保留。

**用了 PVC 后，暂停时必须把 PVC 一并删掉**：local-path PVC 用 `WaitForFirstConsumer` 绑死在某个节点上，
留着它既占本地盘，又会让恢复后的 Pod 被钉回原节点（节点不可调度时直接 `Pending`）。
冒烟数据无保留价值，暂停即清，恢复时由本文 manifest 重新动态供给一个干净 PVC。

```bash
kubectl -n joe-clawchat-dev scale deploy/openclaw-smoke --replicas=0
kubectl -n joe-clawchat-dev delete pvc/openclaw-smoke-data          # 清掉本地盘 PVC
# 恢复：先重建 PVC（重新 apply manifest 即可，幂等），再拉起副本
kubectl apply -f openclaw-smoke.yaml
kubectl -n joe-clawchat-dev scale deploy/openclaw-smoke --replicas=1
kubectl -n joe-clawchat-dev rollout status deploy/openclaw-smoke --timeout=180s
```

> 注意：删 PVC 会清掉 `/home/node/.openclaw`（会话/日志等），恢复后是全新状态；但 LLM 配置（来自 ConfigMap/Secret）不变。

### B. 彻底销毁（默认推荐，测完即弃）

删掉本流程创建的全部四件套（含 PVC），集群里不留任何痕迹：

```bash
kubectl -n joe-clawchat-dev delete deploy/openclaw-smoke \
  cm/openclaw-smoke-config secret/openclaw-smoke-llm \
  pvc/openclaw-smoke-data
```

或者，如果你是用本文那份 `openclaw-smoke.yaml` 起的，直接按文件反向删除最稳妥（不会漏资源）：

```bash
kubectl delete -f openclaw-smoke.yaml
```

删除后 PVC 连同本地盘数据一并回收，不留任何状态。确认已清干净（注意 PVC 不在 `all` 里，单列）：

```bash
kubectl -n joe-clawchat-dev get all,cm,secret,pvc -l app=openclaw-smoke
# 期望：No resources found
```

