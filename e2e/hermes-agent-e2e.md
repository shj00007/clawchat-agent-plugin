# Hermes Agent E2E 环境启动（临时 / 用完即弃）

一种可复现的方式，在 **joe 的测试集群**里快速起一个 `clawchat/hermes-agent` 容器，
配好一个真实 LLM provider，然后通过命令直接发 prompt。**本文提供的是「调试 / 跑测试用例」
所需的环境启动方式** —— 起好这个真实 agent 环境后，可在其上调试 hermes 插件、验证 agent
行为或执行具体测试用例。

> **定位**：临时调试 / 测试环境。`/opt/data` 挂 **`local-path` PVC** —— 数据落在节点本地盘，
> Pod 重启/重建仍在；但这仍是用完即弃的环境，停止时连 PVC 一并清掉，集群里不留痕迹。

当我（Claude）被告知「按这个方式起一个 hermes agent」时，直接照本文执行即可。

---

## 关键坐标

| 项 | 值 |
|---|---|
| kubeconfig | **`~/.kube/dev.config`**（dev 集群凭据 / token，**必须显式使用**） |
| namespace | `joe-clawchat-dev` |
| 镜像 | `192.168.2.129:5000/clawchat/hermes-agent:<tag>`（最新见 registry，曾用 `v2026.5.27`） |
| 镜像 registry | `192.168.2.129:5000`（insecure，dev overlay 已信任，集群可直接拉） |
| LLM 网关 | `http://api.clawling.io/v1`（内部 OpenAI 兼容；key 形如 `sk-crawling-…`） |
| 模型 id | `deepseek-v4-flash`（推理模型）/ `deepseek-v4-pro` / `kimi-k2.6`（查 `/v1/models`） |

> **⚠️ kubectl 凭据：本文所有 `kubectl` 命令都必须走 dev 集群的 `~/.kube/dev.config` token。**
> 默认 kubeconfig 不一定指向这个 dev 集群，不要依赖它。开始前先在当前 shell 执行一次：
> ```bash
> export KUBECONFIG=~/.kube/dev.config
> ```
> 下文命令默认你已 export；若不想改环境，则给每条 kubectl 前缀
> `KUBECONFIG=~/.kube/dev.config kubectl …`。

> 列 registry 里可用 tag：
> `curl -s http://192.168.2.129:5000/v2/clawchat/hermes-agent/tags/list`

---

## 两个必须知道的坑

1. **必须加 `securityContext`（uid/gid/fsGroup = 10000）。**
   镜像 entrypoint 只在「首次以 root 启动」时对数据卷做 `chown -R`；容器一旦**重启**就跳过
   chown，`skills_sync.py` 便对数据卷里的 `/opt/data/skills/.bundled_manifest` 没有写权限，
   `set -e` 直接让 entrypoint 退出 → `CrashLoopBackOff`。换 PVC 后这一点更要命：PVC 跨重启留存，
   一旦首启没 chown 好就会反复崩。以 hermes 用户（10000）+ `fsGroup: 10000` 启动可让数据卷一开始就组可写，
   并绕过这段脆弱的 root-chown 分支。**不要删掉 securityContext。**

2. **`deepseek-v4-flash` 是推理模型。** reasoning token 先消耗额度，`max_tokens` 给太小
   （如 10）只会返回空内容。裸调 API 验证时给足 token（≥200）。`hermes chat` 自己会给够，无需关心。

---

## 启动步骤

### 1. 准备 manifest

把下面内容存成 `hermes-agent-smoke.yaml`（把 `<LLM_KEY>` 换成真实 key，必要时改 `<TAG>` / 模型 id）：

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: hermes-agent-smoke-data
  namespace: joe-clawchat-dev
  labels:
    app: hermes-agent-smoke
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
  name: hermes-agent-smoke-llm
  namespace: joe-clawchat-dev
type: Opaque
stringData:
  api_key: "<LLM_KEY>"            # 形如 sk-crawling-…
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: hermes-agent-smoke-config
  namespace: joe-clawchat-dev
data:
  config.yaml: |
    # 冒烟配置：内部 clawling OpenAI 兼容网关。
    # 不放 ClawChat platform/token —— gateway 离线，直到后续走 connect-code 激活。
    model:
      provider: "custom"
      default: "deepseek-v4-flash"
      base_url: "http://api.clawling.io/v1"
      # api_key 通过 OPENAI_API_KEY 环境变量注入（挂自 Secret）
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hermes-agent-smoke
  namespace: joe-clawchat-dev
  labels:
    app: hermes-agent-smoke
spec:
  replicas: 1
  selector:
    matchLabels:
      app: hermes-agent-smoke
  template:
    metadata:
      labels:
        app: hermes-agent-smoke
    spec:
      securityContext:          # 必须：否则重启后 CrashLoopBackOff（见上文坑 1）
        runAsUser: 10000
        runAsGroup: 10000
        fsGroup: 10000
      # config.yaml 必须是 PVC 里的普通【可写】文件：hermes 在 plugin --enable 和激活时会原子
      # 改写它（os.replace）。若把 ConfigMap 用 subPath 直接挂到 /opt/data/config.yaml 上，该文件
      # 只读，写入会 EBUSY（"Device or resource busy"）失败 → 安装/激活报错。所以把 ConfigMap 挂
      # 到 /seed，再用 initContainer 拷进 PVC（整个 /opt/data 才是可写卷，不要对 config.yaml 用 subPath）。
      initContainers:
        - name: seed-config
          image: 192.168.2.129:5000/clawchat/hermes-agent:v2026.5.27
          command: ["sh", "-c", "cp -n /seed/config.yaml /opt/data/config.yaml 2>/dev/null || true"]
          volumeMounts:
            - name: data
              mountPath: /opt/data
            - name: config
              mountPath: /seed
      containers:
        - name: hermes-agent
          image: 192.168.2.129:5000/clawchat/hermes-agent:v2026.5.27
          # 保持 Pod Running；`hermes` 无参会等 TTY，在 k8s 里会退出。
          args: ["sleep", "infinity"]
          env:
            - name: HERMES_HOME
              value: /opt/data
            - name: OPENAI_API_KEY        # custom/OpenAI 兼容 provider 从这里读 key
              valueFrom:
                secretKeyRef:
                  name: hermes-agent-smoke-llm
                  key: api_key
            - name: OPENROUTER_API_KEY     # 部分回退路径会读它，一并塞同一个 key
              valueFrom:
                secretKeyRef:
                  name: hermes-agent-smoke-llm
                  key: api_key
          volumeMounts:
            - name: data
              mountPath: /opt/data          # 整目录可写；config.yaml 由 initContainer 拷进来，不用 subPath
          resources:
            requests:
              cpu: "100m"
              memory: "256Mi"
            limits:
              cpu: "1"
              memory: "1Gi"
      volumes:
        - name: data
          persistentVolumeClaim:           # local-path PVC，跨重启留存；停止时记得清掉（见「停止/清理」）
            claimName: hermes-agent-smoke-data
        - name: config
          configMap:
            name: hermes-agent-smoke-config
```

### 2. apply 并等待就绪

```bash
kubectl apply -f hermes-agent-smoke.yaml
kubectl -n joe-clawchat-dev rollout status deploy/hermes-agent-smoke --timeout=180s
kubectl -n joe-clawchat-dev get pods -l app=hermes-agent-smoke
```

期望：Pod `1/1 Running`，`RESTARTS 0`。

---

## 发 prompt（核心用法）

通过 `kubectl exec` 让容器里的 `hermes chat -q` 跑一轮非交互对话：

```bash
POD=$(kubectl -n joe-clawchat-dev get pod -l app=hermes-agent-smoke \
        --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')

kubectl -n joe-clawchat-dev exec "$POD" -- bash -lc \
  'source /opt/hermes/.venv/bin/activate; hermes chat -q "你的 prompt 写这里"'
```

- 每次 `-q` 是一轮独立对话；想接着上一轮可加 `hermes --resume <session_id>`（命令输出会给）。
- 想进交互式：`kubectl -n joe-clawchat-dev exec -it "$POD" -- bash`，再 `source .venv/bin/activate && hermes`。

健康自检（确认能接通模型）：

```bash
kubectl -n joe-clawchat-dev exec "$POD" -- bash -lc \
  'source /opt/hermes/.venv/bin/activate; hermes chat -q "reply with exactly: HERMES-OK"'
```

---

## 排错

```bash
# 看日志（崩溃时加 --previous 看上一个容器）
kubectl -n joe-clawchat-dev logs -l app=hermes-agent-smoke --tail=60
kubectl -n joe-clawchat-dev logs <pod> --previous

# 看重启/退出原因
kubectl -n joe-clawchat-dev describe pod -l app=hermes-agent-smoke | sed -n '/Events:/,$p'
```

- `PermissionError … /opt/data/skills/.bundled_manifest` → 漏了 `securityContext`（坑 1）。
- 裸调 API 返回空内容 → `max_tokens` 太小，推理模型（坑 2）。
- 直接验证网关/模型可用性：
  ```bash
  curl -s http://api.clawling.io/v1/models -H "Authorization: Bearer <LLM_KEY>"
  ```

---

## 停止 / 清理

这是临时冒烟环境，**测完务必停掉**。按需选其一：

### A. 临时暂停（保留配置，之后能快速恢复）

把副本缩到 0：Pod 销毁，但 Deployment / ConfigMap / Secret 保留。

**用了 PVC 后，暂停时必须把 PVC 一并删掉**：local-path PVC 用 `WaitForFirstConsumer` 绑死在某个节点上，
留着它既占本地盘，又会让恢复后的 Pod 被钉回原节点（节点不可调度时直接 `Pending`）。
冒烟数据无保留价值，暂停即清，恢复时由本文 manifest 重新动态供给一个干净 PVC。

```bash
kubectl -n joe-clawchat-dev scale deploy/hermes-agent-smoke --replicas=0
kubectl -n joe-clawchat-dev delete pvc/hermes-agent-smoke-data          # 清掉本地盘 PVC
# 恢复：先重建 PVC（重新 apply manifest 即可，幂等），再拉起副本
kubectl apply -f hermes-agent-smoke.yaml
kubectl -n joe-clawchat-dev scale deploy/hermes-agent-smoke --replicas=1
kubectl -n joe-clawchat-dev rollout status deploy/hermes-agent-smoke --timeout=180s
```

> 注意：删 PVC 会清掉 `/opt/data`（会话/日志/.env 等），恢复后是全新状态；但 LLM 配置（来自 ConfigMap/Secret）不变。

### B. 彻底销毁（默认推荐，测完即弃）

删掉本流程创建的全部四件套（含 PVC），集群里不留任何痕迹：

```bash
kubectl -n joe-clawchat-dev delete deploy/hermes-agent-smoke \
  cm/hermes-agent-smoke-config secret/hermes-agent-smoke-llm \
  pvc/hermes-agent-smoke-data
```

或者，如果你是用本文那份 `hermes-agent-smoke.yaml` 起的，直接按文件反向删除最稳妥（不会漏资源）：

```bash
kubectl delete -f hermes-agent-smoke.yaml
```

删除后 PVC 连同本地盘数据一并回收，不留任何状态。确认已清干净（注意 PVC 不在 `all` 里，单列）：

```bash
kubectl -n joe-clawchat-dev get all,cm,secret,pvc -l app=hermes-agent-smoke
# 期望：No resources found
```
