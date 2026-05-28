# clawchat-agent-plugin docs

> 中文版本：[`README.zh.md`](./README.zh.md)

This repo aggregates three submodules: two **runtime adapter plugins**
(`openclaw-clawchat`, `hermes-clawchat`) that connect an agent to ClawChat over
Protocol v2, and a CLI installer (`openclaw-clawchat-cli`). Actual code work
happens inside each submodule; this top-level `docs/` holds **cross-plugin**
material only.

## Cross-plugin

- [`openclaw-vs-hermes.md`](./openclaw-vs-hermes.md) — full comparison of the
  two adapters: shared Protocol-v2 contract, the differences (host integration,
  config/secret storage, persistence, activation, addressing), a config key
  cross-reference, and a "keeping the two in sync" maintenance guide.

## Per-submodule docs (authoritative)

Each submodule owns its own deep docs; treat those as the source of truth.

| Submodule              | Start here                                              |
| ---------------------- | ------------------------------------------------------- |
| `openclaw-clawchat`    | [`../openclaw-clawchat/docs/README.md`](../openclaw-clawchat/docs/README.md) · plugin reference `openclaw-clawchat/docs/openclaw-clawchat.md` |
| `hermes-clawchat`      | [`../hermes-clawchat/docs/README.md`](../hermes-clawchat/docs/README.md) |
| `openclaw-clawchat-cli`| [`../openclaw-clawchat-cli/README.md`](../openclaw-clawchat-cli/README.md) |

## Upstream contract (owned elsewhere)

The ClawChat Protocol v2 wire contract is owned by `clawchat-msghub`
(`docs/features/msghub/protocol-v2-*.md`). Both adapters are peer clients of it;
change the msghub reference first, then mirror into both plugins.
