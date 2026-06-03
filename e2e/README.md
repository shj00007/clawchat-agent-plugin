# E2E 环境启动文档索引

本目录收录 ClawChat agent 插件的**端到端（e2e）环境启动**文档。每篇都是可复现的 runbook：
在 joe 测试集群里临时起一个真实 agent 容器、接一个真实 LLM provider，然后直接发 prompt。

> **这些不是冒烟测试文档**，而是「**调试 / 跑测试用例**」所需的**环境启动方式**：起好这个
> 真实 agent 环境后，你可以在其上调试插件、验证 agent 行为，或执行具体的测试用例。
> 环境均为**临时 / 用完即弃**，用完按文档「停止 / 清理」一节销毁。

> 何时用：需要对 `clawchat-plugin-hermes-agent` 或 `clawchat-plugin-openclaw` 做端到端调试 / 测试，
> 或被要求「按这个方式起一个 hermes / openclaw agent」时，直接照对应文档执行。

## 文件索引

| 文档 | 适用插件 | 说明 |
|------|----------|------|
| [`hermes-agent-e2e.md`](hermes-agent-e2e.md) | `clawchat-plugin-hermes-agent`（Python / Hermes） | 在 joe 集群起 `clawchat/hermes-agent` 容器（uid 10000），用 `hermes chat -q` 非交互发 prompt。 |
| [`openclaw-agent-e2e.md`](openclaw-agent-e2e.md) | `clawchat-plugin-openclaw`（TS / OpenClaw） | 在 joe 集群起 `clawchat/openclaw` 容器（node, uid 1000），用 `openclaw.mjs agent` 走 agent loop（`infer model run` 仅作裸 LLM 自检）。 |

## 公共要点

- **kubeconfig**：所有 `kubectl` 命令都走 dev 集群凭据 `~/.kube/dev.config`，先 `export KUBECONFIG=~/.kube/dev.config`。
- **namespace**：`joe-clawchat-dev`。
- **镜像 registry**：`192.168.2.129:5000`（insecure，dev overlay 已信任）。
- **LLM 网关**：`http://api.clawling.io/v1`（内部 OpenAI 兼容；key 形如 `sk-crawling-…`）。
- **用完即清**：local-path PVC 跨重启留存，但停止时务必连 PVC 一并删除，集群不留痕迹。
