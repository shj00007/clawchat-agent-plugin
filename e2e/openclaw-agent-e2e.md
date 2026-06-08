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
> lib（[`lib/openclaw-env.sh`](lib/openclaw-env.sh)）会自动 `export KUBECONFIG`（默认 `~/.kube/dev.config`，
> 可在 `e2e/.env` 用 `KUBECONFIG_PATH` 覆盖）。手动跑 `kubectl` 时记得先：
> ```bash
> export KUBECONFIG=~/.kube/dev.config
> ```

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

环境的唯一来源是 [`lib/openclaw-env.sh`](lib/openclaw-env.sh)（manifest 内嵌其中），它已落地下面三个要点：

1. **密钥只进 Secret，不落配置。** OpenClaw 内置 `deepseek` provider 会自动读环境变量
   `DEEPSEEK_API_KEY`，所以配置（ConfigMap 里的 `openclaw.json`）只覆盖非敏感的 `baseUrl`，key 走 Secret → env。
2. **必须覆盖默认 cmd。** 镜像默认 `node openclaw.mjs gateway` 需要 ClawChat token，
   冒烟阶段没有会起不来；manifest 用 `args: ["sleep","infinity"]` 让 Pod 闲置，再用 `exec` / `chat` 驱动。
3. **必须设 `HOME=/home/node`** 且 `securityContext` 用 1000，否则 `~/.openclaw` 路径/写权限不对。
   `openclaw.json` 由 initContainer 拷进 PVC（整目录可写），不对它用 ConfigMap subPath（只读 → 安装写 base-url 会失败）。

> `deepseek-v4-flash` 是推理模型：会先吐一段 `reasoning_content` 再出正文，所以
> openclaw `agent` / `infer model run` 单次本就慢（几十秒级），且**首调偶发卡 ~2min 后报
> `No text output returned ... terminated`**——这是插件侧流式收尾的偶发问题，不是配置错，
> **原样重试一次**通常即过（已复现：同一条命令首调 terminated、二调成功）。要快速排除
> 「是不是网关/模型挂了」，用下方的直连 `curl`（非流式、秒回）。
> 注意模型可能自报为 "DeepSeek-V3/R1"（自我认知幻觉），实际走的模型以命令输出的
> `provider: deepseek / model: deepseek-v4-flash` 为准。

---

## 启动步骤

先把凭据填进 `e2e/.env`（见 [`.env.example`](.env.example)）：至少 `LLM_API_KEY`（clawling 网关
key），其余 `NAMESPACE` / `OPENCLAW_IMAGE_TAG` / `KUBECONFIG_PATH` / `OPENCLAW_SESSION_KEY` 有默认值。然后：

```bash
e2e/lib/openclaw-env.sh up        # 建 Secret + apply manifest（PVC+CM+Deploy）+ 等 rollout（幂等）
e2e/lib/openclaw-env.sh status    # 期望 pod 1/1 Running、RESTARTS 0、PVC Bound
```

> lib 自动 `export KUBECONFIG`。列 registry 可用 tag：
> `curl -s http://192.168.2.129:5000/v2/clawchat/openclaw/tags/list`

---

## 跟 openclaw 对话（核心用法）

`chat` 走 **agent loop**（系统提示、会话状态、工具语义）—— 这才是「跟 openclaw 对话」：

```bash
e2e/lib/openclaw-env.sh chat "你的话写这里"
```

- **多轮对话**：默认会话 key 是 `agent:default:smoke-test`（可用 `e2e/.env` 的 `OPENCLAW_SESSION_KEY`
  覆盖）；复用同一 key 续上下文，换 key 即开新会话。
- **首调卡住/报 `terminated` → 原样重试一次**（见上文模型说明），别去改配置。
- 交互式 TUI：`e2e/lib/openclaw-env.sh exec -it -- node openclaw.mjs chat`（全屏终端 UI）。

> ⚠️ **`infer model run` 不是「跟 openclaw 对话」。** 它只是把 prompt **裸透传给 LLM
> provider**（单轮、无系统提示 / 无会话 / 无工具），openclaw 在这里只是个壳。它适合当
> 「provider 接线通不通」的健康自检，**不要**拿它当 agent 行为的 e2e —— 真正测 agent 用 `chat`。

### 健康自检（先快后全）

**① 快路径：直连网关（非流式，~1～2s）。** 最快确认「网关 + key + 模型」是活的，
也能把网关问题和 openclaw 插件问题切开 —— 首选的「是不是活着」检查：

```bash
KEY=$(kubectl -n joe-clawchat-dev get secret openclaw-smoke-llm -o jsonpath='{.data.api_key}' | base64 -d)
e2e/lib/openclaw-env.sh exec -- sh -c "curl -s -m 30 http://api.clawling.io/v1/chat/completions \
  -H \"Authorization: Bearer $KEY\" -H 'Content-Type: application/json' \
  -d '{\"model\":\"deepseek-v4-flash\",\"messages\":[{\"role\":\"user\",\"content\":\"reply with exactly: OPENCLAW-OK\"}],\"max_tokens\":2048}'"
# 期望：choices[0].message.content == "OPENCLAW-OK"（前面会有 reasoning_content，正常）
```

**② 中路径：provider 接线（裸 LLM 透传，非 agent）。** 验证 openclaw↔provider 接线通不通，
但**不走 agent loop**（慢；首调失败就重试一次）：

```bash
e2e/lib/openclaw-env.sh exec -- node openclaw.mjs infer model run --local \
  --model deepseek/deepseek-v4-flash --prompt "reply with exactly: OPENCLAW-OK"
# 期望末行：OPENCLAW-OK
```

**③ 全路径：agent loop（真正的「跟 openclaw 对话」）。** = lib 的 `health`（跑一轮真实 agent）：

```bash
e2e/lib/openclaw-env.sh health     # 发 "reply with exactly: OPENCLAW-OK"，回复正文应含 OPENCLAW-OK
```

需要进容器排查：`e2e/lib/openclaw-env.sh exec -- bash`（或 `exec -- <cmd>` 跑单条命令）。

---

## 排错

> 下列命令需 KUBECONFIG=~/.kube/dev.config；或先用 e2e/lib/openclaw-env.sh exec -- <cmd> 进容器。

```bash
kubectl -n joe-clawchat-dev logs -l app=openclaw-smoke --tail=60
kubectl -n joe-clawchat-dev logs <pod> --previous
kubectl -n joe-clawchat-dev describe pod -l app=openclaw-smoke | sed -n '/Events:/,$p'

# 容器内确认 provider 配置生效 / 列模型
e2e/lib/openclaw-env.sh exec -- node openclaw.mjs config get models.providers.deepseek.baseUrl
e2e/lib/openclaw-env.sh exec -- node openclaw.mjs infer model providers

# 直接验证网关/模型可用性
curl -s http://api.clawling.io/v1/models -H "Authorization: Bearer <LLM_KEY>"
```

- 权限 / `~/.openclaw` 报错 → 漏了 `HOME=/home/node` 或 `securityContext`（uid/gid/fsGroup=1000）。
- Pod 起不来且日志在等 token → 跑成了默认 `gateway`（manifest 已用 `sleep infinity`，不该再遇到）。
- `agent`/`infer` 卡 ~2min 后 `No text output returned ... terminated`，但直连 `curl` 正常 →
  插件侧流式收尾偶发问题，**不是配置错；原样重试一次**即可（已复现首调失败、二调成功）。
- **改了 ConfigMap 但不生效** → initContainer 用 `cp -n`（不覆盖已存在文件），PVC 里那份
  `openclaw.json` 还是旧的。删 PVC（或卷里那份文件）再起：`pause` 后 `resume`（见下）。

---

## 停止 / 清理

这是临时环境，测完务必停掉：

```bash
e2e/lib/openclaw-env.sh pause     # 暂停：scale 0 + 删 PVC（之后 resume 重建干净 PVC 恢复）
e2e/lib/openclaw-env.sh resume    # 恢复（= up）
e2e/lib/openclaw-env.sh down      # 彻底销毁四件套（含 PVC），集群不留痕
```

> 用了 local-path PVC：pause/down 都会删掉它（绑死节点、无保留价值）。删 PVC 会清掉
> `/home/node/.openclaw`（会话/日志，**以及 initContainer 从 ConfigMap 拷入的 `openclaw.json`**），
> resume 后 initContainer 会重新拷一份干净的。down 后用
> `e2e/lib/openclaw-env.sh status` 确认 `No resources found`。
