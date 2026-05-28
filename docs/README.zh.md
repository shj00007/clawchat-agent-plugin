# clawchat-agent-plugin 文档

> English: [`README.md`](./README.md)

本仓库聚合了三个 submodule：两个**运行时适配器插件**
（`openclaw-clawchat`、`hermes-clawchat`），它们通过 Protocol v2 把 agent 接入
ClawChat；以及一个 CLI 安装器（`openclaw-clawchat-cli`）。实际的代码工作发生在
各 submodule 内部；本顶层 `docs/` 仅存放**跨插件**材料。

## 跨插件

- [`openclaw-vs-hermes.zh.md`](./openclaw-vs-hermes.zh.md) —— 两个适配器的完整
  对比：共享的 Protocol-v2 契约、差异（宿主集成、配置/密钥存储、持久化、激活、
  寻址）、一份配置键交叉对照表，以及一份"保持两者同步"的维护指引。

## 各 submodule 文档（权威）

每个 submodule 拥有自己的深入文档；以那些为准。

| Submodule              | 从这里开始                                              |
| ---------------------- | ------------------------------------------------------- |
| `openclaw-clawchat`    | [`../openclaw-clawchat/docs/README.md`](../openclaw-clawchat/docs/README.md) · 插件参考 `openclaw-clawchat/docs/openclaw-clawchat.md` |
| `hermes-clawchat`      | [`../hermes-clawchat/docs/README.md`](../hermes-clawchat/docs/README.md) |
| `openclaw-clawchat-cli`| [`../openclaw-clawchat-cli/README.md`](../openclaw-clawchat-cli/README.md) |

## 上游契约（由别处拥有）

ClawChat Protocol v2 线路契约由 `clawchat-msghub`
（`docs/features/msghub/protocol-v2-*.md`）拥有。两个适配器都是它的对等客户端；
请先改 msghub 参考文档，再镜像到两个插件中。
