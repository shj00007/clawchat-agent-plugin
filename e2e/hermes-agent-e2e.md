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

## 三个必须知道的坑

1. **必须加 `securityContext`（uid/gid/fsGroup = 10000）。**
   镜像 entrypoint 只在「首次以 root 启动」时对数据卷做 `chown -R`；容器一旦**重启**就跳过
   chown，`skills_sync.py` 便对数据卷里的 `/opt/data/skills/.bundled_manifest` 没有写权限，
   `set -e` 直接让 entrypoint 退出 → `CrashLoopBackOff`。换 PVC 后这一点更要命：PVC 跨重启留存，
   一旦首启没 chown 好就会反复崩。以 hermes 用户（10000）+ `fsGroup: 10000` 启动可让数据卷一开始就组可写，
   并绕过这段脆弱的 root-chown 分支。**不要删掉 securityContext。**

2. **`deepseek-v4-flash` 是推理模型。** reasoning token 先消耗额度，`max_tokens` 给太小
   （如 10）只会返回空内容。裸调 API 验证时给足 token（≥200）。`hermes chat` 自己会给够，无需关心。

3. **LLM key 必须落到 `$HERMES_HOME/.env`，光靠 Pod 环境变量不够。**
   `hermes chat -q` 是 `kubectl exec` 起的新进程、继承 Pod env，能读到 `OPENAI_API_KEY`，所以
   永远「正常」；但 **clawchat channel 跑的是常驻 gateway daemon**，它经 clawchat 激活 /
   `gateway restart` 后只从 `$HERMES_HOME/.env` 加载 provider key——`clawchat_gateway/restart.py`
   继承的是调用方 `os.environ`，而激活只往 `.env` 写 `CLAWCHAT_*`、不写 provider key，于是 gateway
   并不可靠地继承 Pod env。config 又是 `provider: custom` 且**没有内联 `api_key`**，key 只在 Pod env
   里时 gateway 调网关就是空 key → **从 channel 发消息返回 `401 Invalid API key`，而 `chat -q`
   一切正常**（极具迷惑性）。所以 lib（[`lib/hermes-env.sh`](lib/hermes-env.sh)）的 manifest 里 initContainer 会把 key 一并 seed 进 `/opt/data/.env`。
   排错时确认：`tr '\0' '\n' < /proc/$(pgrep -f 'hermes gateway')/environ | grep OPENAI_API_KEY`。

---

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

---

## 发 prompt（核心用法）

```bash
e2e/lib/hermes-env.sh chat "你的 prompt 写这里"
e2e/lib/hermes-env.sh health          # 自检：应回 HERMES-OK
```

需要进容器排查：`e2e/lib/hermes-env.sh exec -- bash`（或 `exec -- <cmd>` 跑单条命令）。

---

## 排错

> 下列命令需 KUBECONFIG=~/.kube/dev.config；或先用 e2e/lib/hermes-env.sh exec -- <cmd> 进容器。

```bash
# 看日志（崩溃时加 --previous 看上一个容器）
kubectl -n joe-clawchat-dev logs -l app=hermes-agent-smoke --tail=60
kubectl -n joe-clawchat-dev logs <pod> --previous

# 看重启/退出原因
kubectl -n joe-clawchat-dev describe pod -l app=hermes-agent-smoke | sed -n '/Events:/,$p'
```

- `PermissionError … /opt/data/skills/.bundled_manifest` → 漏了 `securityContext`（坑 1）。
- 裸调 API 返回空内容 → `max_tokens` 太小，推理模型（坑 2）。
- **从 clawchat channel 发消息返回 `401 Invalid API key`，但 `hermes chat -q` 正常** → gateway
  daemon 的环境里没有 provider key（坑 3）。查 `tr '\0' '\n' < /proc/$(pgrep -f 'hermes gateway')/environ | grep OPENAI_API_KEY`；
  补救：`grep -q '^OPENAI_API_KEY=' /opt/data/.env || echo "OPENAI_API_KEY=<LLM_KEY>" >> /opt/data/.env`，
  再 `hermes gateway restart`（新版 manifest 的 initContainer 已自动 seed，不该再遇到）。
- 直接验证网关/模型可用性：
  ```bash
  curl -s http://api.clawling.io/v1/models -H "Authorization: Bearer <LLM_KEY>"
  ```

---

## 停止 / 清理

这是临时环境，测完务必停掉：

```bash
e2e/lib/hermes-env.sh pause     # 暂停：scale 0 + 删 PVC（之后 resume 重建干净 PVC 恢复）
e2e/lib/hermes-env.sh resume    # 恢复（= up）
e2e/lib/hermes-env.sh down      # 彻底销毁四件套（含 PVC），集群不留痕
```

> 用了 local-path PVC：pause/down 都会删掉它（绑死节点、无保留价值）。down 后用
> `e2e/lib/hermes-env.sh status` 确认 `No resources found`。
