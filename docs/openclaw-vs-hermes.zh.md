# openclaw-clawchat 与 hermes-clawchat 对比

> English: [`openclaw-vs-hermes.md`](./openclaw-vs-hermes.md)

本文档并排对比本工作区内捆绑的两个 ClawChat agent 适配器。两者都通过
**Protocol v2**（WebSocket + 一个小的 REST 接口）把 agent 运行时接入 ClawChat。
它们被刻意设计成**同一契约的两个对等适配器**：一个用 TypeScript 面向 OpenClaw
宿主，一个用 Python 面向 Hermes 宿主。

> **权威来源（Sources of truth）。** 这里的每一条结论都来自各 submodule 自身的
> 权威文档 —— `clawchat-plugin-openclaw/docs/openclaw-clawchat.md` 和
> `clawchat-plugin-hermes-agent/docs/`。线路协议本身由 `clawchat-msghub`
> （`docs/features/msghub/protocol-v2-*.md`）拥有，两个插件都不定义它。当本文档
> 与某个 submodule 文档冲突时，以 submodule 文档为准。参见
> [权威来源指引](#权威来源指引)。

---

## 1. 概览与定位

**`openclaw-clawchat`** 是一个 OpenClaw **channel 插件**（TypeScript），以
`@newbase-clawchat/openclaw-clawchat` 发布到 npm。它注册 `openclaw-clawchat`
channel，自持一个 Protocol-v2 WebSocket 客户端，并暴露一组 `clawchat_*` agent
工具。它把运行态状态持久化在一个插件自有的 SQLite 数据库中。

**`hermes-clawchat`** 是一个 Hermes Agent **gateway platform 插件**（Python，
发行包名 `clawchat-gateway`，Hermes 插件 id 为 `clawchat`）。它在一个运行中的
Hermes Agent v0.12.0+ 进程内通过 `ctx.register_platform(...)` 注册一个
`clawchat` gateway platform，提供同样的 `clawchat_*` 工具和一个捆绑 skill，并且
**不使用任何数据库** —— 它唯一的持久状态是文件形态的 memory。

终端用户侧，两者由同一个安装器驱动
（`@newbase-clawchat/clawchat-cli`，通过 `install --target openclaw|hermes`），
并且都通过在 `POST /v1/agents/connect` 兑换一个一次性 code 来完成接入。

---

## 2. 身份速览矩阵

| 维度                 | openclaw-clawchat                              | hermes-clawchat                                            |
| -------------------- | ---------------------------------------------- | ---------------------------------------------------------- |
| 语言                 | TypeScript                                     | Python（`>=3.11`）                                         |
| 宿主运行时           | OpenClaw                                        | Hermes Agent `v0.12.0+`                                    |
| 宿主集成形态         | **Channel** 插件                               | **Gateway platform** 插件                                  |
| 发布产物             | npm `@newbase-clawchat/openclaw-clawchat`      | wheel `clawchat-gateway`；Hermes 插件 id `clawchat`        |
| 源 spec              | `clawling/openclaw-clawchat`                   | `clawling/hermes-clawchat`                                 |
| Manifest             | `openclaw.plugin.json`（`kind: channel`）      | `plugin.yaml`（`kind: platform`）                          |
| 入口                 | `index.ts`（运行时）+ `setup-entry.ts`（setup）| `__init__.py` → `register(ctx)`（单一入口）                |
| 运行时代码目录       | `src/`                                         | `clawchat_gateway/`                                        |
| 安装位置             | 由 OpenClaw 加载的 npm 依赖                     | 拷贝进 `$HERMES_HOME/plugins/clawchat/`                    |
| 配置存储             | `openclaw.json`（JSON5，camelCase）            | `config.yaml` `platforms.clawchat.extra.*`（snake_case）   |
| 密钥存储             | 写在 `openclaw.json` 的 channel 段内           | **仅** `$HERMES_HOME/.env`（绝不进 `config.yaml`）         |
| 运行态状态           | 插件自有 **SQLite** `clawchat.sqlite`          | **无**（不使用数据库）                                     |
| 持久 memory          | 文件形态，位于 OpenClaw workspace 根目录下     | 文件形态，位于 `$HERMES_HOME/memories` 下                  |
| 测试                 | `npm test`（Vitest）                           | `uv run pytest`（checkout 中不跟踪 `tests/`）              |
| 版本标记             | `package.json`                                 | `plugin.yaml`（撰写时为 `0.14.0-15`）                      |

---

## 3. 完全相同的部分（共享契约）

以下行为在两个适配器中被规定为一致。当你改动其中之一时，几乎总是必须在另一个里
同步 —— 参见 [§6 保持两者同步](#6-保持两者同步)。

### Protocol-v2 客户端行为
- **握手：** `connect.challenge { nonce }` → `connect { token, nonce,
  device_id?, capabilities: [multi_device, device_replay, chat_meta_events] }`
  → `hello-ok { device_id?, delivery_mode? }`。`hello-fail` 对当前凭据是终态
  （凭据刷新前不再重连）。
- **重连：** 指数退避，`initialDelay 500ms`、`maxDelay 15000ms`、
  `jitterRatio 0.3`、`maxRetries ∞`；连接稳定 `5000ms` 后重置退避计数。
- **心跳：** JSON `ping`/`pong` 协议帧（非原生 WS ping），`interval 20000ms`、
  `timeout 10000ms` 后拆链并重连。
- **Ack：** 仅作用于 `message.send` / `message.reply`；`timeout 15000ms`、
  `autoResendOnTimeout false`。`message.error` 是负向 ack。

### 消息与流式
- **回复模式：** `static` 与 `stream`（默认 `stream`）。
- **流式默认值：** `flushIntervalMs 250`、`minChunkChars 40`、
  `maxBufferChars 2000`。
- **流式生命周期：** `message.created` → 多个 `message.add` → `message.done`，
  随后是一条整合后的、**可 ack 的** `message.reply`；这四类帧共享同一个
  agent 侧 `message_id`（绝不复用入站用户的 id）。会话在首个真实内容出现时
  **惰性**打开；空运行不发出任何帧。
- **媒体+流式：** 携带媒体的回复会被强制为 `static` 模式（流式 + 媒体在线路上
  不被支持）。

### 群组行为
- `groupMode`：`all`（默认）| `mention`。
- `groupCommandMode`：`owner`（默认）| `all` | `off`。
- 按群覆盖的优先级解析顺序：精确 `chat_id` → `"*"` 通配 → channel/顶层。
- **合并（coalescing）：** 未 @ 机器人的群消息会被合并成一次 agent 轮次，
  触发条件是 **10s** 无新消息或自首条缓存消息起 **30s** 上限；@ 了机器人的消息
  立即派发。

### REST 接口（`/v1/*` + 无版本号的 `/media/upload`）
- `POST /v1/agents/connect`、`GET /v1/users/me`、`PATCH /v1/users/me`、
  `GET /v1/users/<id>`、`GET /v1/friendships`、`GET /v1/conversations`、
  `GET /v1/conversations/<id>`、`GET /v1/agents/{id}`、
  `POST /v1/files/upload-url`、`POST /media/upload`。
- 统一信封 `{ "code": 0, "msg": "ok", "data": ... }`；非零 `code` 抛出 API 错误。
  每个请求带 `Authorization: Bearer <token>` + `X-Device-Id`。

### Agent 工具 —— 同样的 **22** 个 `clawchat_*` 工具
账号/身份（`get_account_profile`、`update_account_profile`、
`upload_avatar_image`），用户/好友（`list_account_friends`、`search_users`、
`get_user_profile`），会话/提及（`get_conversation`、`mention_message`），
动态 moments（`list_moments`、`create_moment`、`delete_moment`、
`toggle_moment_reaction`、`create_moment_comment`、`reply_moment_comment`、
`delete_moment_comment`），媒体（`upload_media_file`），本地 memory
（`memory_search`、`memory_read`、`memory_write`、`memory_edit`），以及服务端
权威 metadata（`metadata_sync`、`metadata_update`）。
`clawchat_mention_message` 在两者中都是**终结性发送（terminal send）**：成功后，
同一轮次的普通后续回复会被抑制。

### 文件形态 memory 契约
- 相同布局：`owner.md`、`users/<id>.md`、`groups/<id>.md`。
- 相同的职责切分：memory 工具（`memory_*`）只写 agent 撰写的正文；metadata 工具
  （`metadata_*`）拥有 metadata 块。
- 相同的可写 metadata 字段：`owner` → `agent_behavior`；`user` →
  `nickname`/`avatar_url`/`bio`；`group` → `group_title`/`group_description`。
- （仅**根目录**不同 —— 见 §5。）

### 提示词与 skill
- 必需的 `prompts/platform.md`，外加 `prompts/default-owner-behavior.md` 和
  `prompts/default-group-bio.md`。
- 一个捆绑的 `clawchat` skill，位于 `skills/clawchat/SKILL.md`。

### 媒体处理
- **入站：** `image`/`file`/`audio`/`video` 片段会被下载（每个上限 **20 MB**）
  并以本地路径暴露；正文保留一个 markdown 占位符。
- **出站：** 资源通过 `POST /media/upload` 上传；头像通过独立的
  `POST /v1/files/upload-url`。

### 接入（onboarding）
- 两者都通过 `POST /v1/agents/connect` 兑换一次性 code，拿到 `access_token` +
  `refresh_token` + agent profile + 一个 `conversation.id`。
- 两者都暴露会话内的 `/clawchat-activate <code>` 斜杠命令。

---

## 4. 差异（按维度）

### (a) 语言与模块布局
TypeScript 与 Python，模块命名高度对称。大致对应关系：

| 关注点                | openclaw-clawchat（`src/`）        | hermes-clawchat（`clawchat_gateway/`）|
| --------------------- | ---------------------------------- | ------------------------------------- |
| WS 传输               | `ws-client.ts`                     | `connection.py`                       |
| 入站解析              | `inbound.ts`                       | `inbound.py`                          |
| 出站帧                | `outbound.ts` / `protocol.ts`      | `protocol.py`                         |
| REST 客户端           | `api-client.ts`                    | `api_client.py`                       |
| 流式缓冲              | `buffered-stream.ts`               | `stream_buffer.py`                    |
| 群组合并              | `group-message-coalescer.ts`       | `group_message_coalescer.py`          |
| 工具                  | `tools.ts` / `tools-schema.ts`     | `tools.py` / `plugin_tools.py`        |
| Memory                | `clawchat-memory.ts`               | `clawchat_memory.py`                  |
| 配置                  | `config.ts`                        | `config.py`                           |

### (b) 宿主集成模型
- **OpenClaw —— 刻意采用两个入口。** `setup-entry.ts` 是**仅 setup**
  （channel 元数据、配置适配器、setup 适配器、计算出的 status）。它**不得**为
  `channels.openclaw-clawchat` 声明 `reload.configPrefixes`，也**不得**写入一个
  已启用的、无凭据的 channel 骨架。`index.ts` 是**完整运行时**
  （声明 `reload.configPrefixes: ["channels.openclaw-clawchat"]`、`auth.login`、
  `gateway.startAccount`、出站消息、`agentPrompt`）。激活会在**一次**配置变更中
  写入凭据 + `plugins.allow` + `plugins.entries` + `tools.alsoAllow`，并带上
  重启意图。
- **Hermes —— 单一入口。** `register(ctx)` 依次调用：
  `register_platform(name="clawchat", adapter_factory, setup_fn, check_fn,
  validate_config, is_connected)`、`register_hook("pre_gateway_dispatch")`、
  `register_tool(...)` ×22、`register_skill("clawchat")`、
  `register_cli_command("clawchat")`、`register_command("clawchat-activate")`。
  适配器是 `ClawChatAdapter(BasePlatformAdapter)`。

### (c) 配置与密钥存储
- **OpenClaw：** 所有配置（含 `token`/`refreshToken`）都在 `openclaw.json` 的
  `channels.openclaw-clawchat.*` 下，键名 camelCase。插件启用状态分散在
  `plugins.allow`、`plugins.entries` 和 `tools.alsoAllow` 中。
- **Hermes：** 解析顺序为 **进程环境变量（`CLAWCHAT_*`）→
  `hermes_cli.config.get_env_value` → `$HERMES_HOME/.env` →
  `platforms.clawchat.extra` → dataclass 默认值**，键名 snake_case。密钥
  （`token`/`refresh_token`）**仅**存于 `.env`；激活会显式 pop 掉 `token`，使其
  绝不落入 `config.yaml`。插件加载时还会写入顶层 `streaming.*` 和
  `display.platforms.clawchat.*` 块。

完整的键/环境变量/默认值映射（以及一处需要注意的**默认值分歧**）见
[§5 配置键交叉对照](#5-配置键交叉对照)。

### (d) 持久化与状态
- **OpenClaw** 维护一个惰性创建的、插件自有的 SQLite 数据库
  （`clawchat.sqlite`，WAL 模式），表有 `schema_migrations`、`activations`、
  `connections`、`clawchat_messages`（消息幂等，按
  `(account_id, direction, kind, message_id)`）和 `tool_calls`。它绝不存储
  token 或端点 URL。
- **Hermes** **没有数据库**。唯一的持久状态是位于 `$HERMES_HOME/memories` 下的
  文件形态 memory。

### (e) 自回声与幂等
- **OpenClaw：** 入站消息在派发前先在 SQLite 中认领（claim）（重复则跳过，
  认领失败则 fail open）；出站发送在写入前认领（重复则 fail closed）。
- **Hermes：** 一个 `pre_gateway_dispatch` **hook** 会丢弃任何 `source.user_id`
  等于机器人自身 `user_id` 的入站帧（每次调用都实时重新解析，从不缓存）。没有它，
  Hermes 的 interrupt-on-new-message 逻辑会把机器人自身分片的 WS 回声误当作新的
  用户输入。

### (f) 激活引导问候（bootstrap greeting）
- **OpenClaw：** 若 `/v1/agents/connect` 返回了 `conversation.id`，下一次就绪的
  WS 连接会原子地认领一个 SQLite 支撑的 bootstrap，经正常路由注入一条合成的直聊
  入站轮次，然后置 `bootstrap_sent=true`。
- **Hermes：** 激活会把 `CLAWCHAT_HOME_CHANNEL` 设为返回的 conversation id
  （并设 `CLAWCHAT_HOME_CHANNEL_NAME=ClawChat`），从而启用插件的 home-channel
  模式。

### (g) 出站目标寻址
- **OpenClaw：** `sendText({ to, text })`；`to` 字符串由一个 URI scheme 解析器
  解析，接受 `cc:` / `clawchat:` / `openclaw-clawchat:`（可带 `:direct:` /
  `:group:`）、OpenClaw 归一化后的 `direct:` / `group:`，或裸 `chat_id`
  （默认直聊）。
- **Hermes：** 对 Hermes 内置的 `tools.send_message_tool._parse_target_ref` 做
  monkey-patch，使得 `platform="clawchat"` 且以 `cnv_` 开头的目标被识别为显式
  conversation id。该补丁范围窄且幂等（`_clawchat_target_patch=True`）。

### (h) 宿主特有概念
- **仅 Hermes：** `CLAWCHAT_ALLOWED_USERS` / `CLAWCHAT_ALLOW_ALL_USERS`
  （插件加载时默认置为 `true`）馈入 Hermes 平台的用户白名单；
  `CLAWCHAT_HOME_CHANNEL*` 驱动 home-channel 模式；`send_message` 解析器补丁与
  `pre_gateway_dispatch` hook 都是对 Hermes 运行时的适配。
- **仅 OpenClaw：** ClawChat 入站被强制为
  `session.dmScope: "per-account-channel-peer"`，使每个 账号+channel+对端 拥有
  各自的 session；群组回复派发把 OpenClaw 源回复强制为 `automatic`。两入口
  setup/runtime 边界以及 SQLite 存储也是 OpenClaw 独有。

### 激活与安装 CLI

| 动作              | openclaw-clawchat                                              | hermes-clawchat                                                                          |
| ----------------- | ------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| 安装器封装        | `npx … clawchat-cli install --target openclaw`                | `npx … clawchat-cli install --target hermes`                                             |
| 原生安装          | `openclaw plugins install/update`（npm）                      | `hermes plugins install clawling/hermes-clawchat` + `hermes plugins enable clawchat`     |
| 激活（CLI）       | `openclaw channels add --channel openclaw-clawchat --token <code>` | `hermes gateway setup` · `hermes clawchat activate <CODE>` · `python clawchat_cli.py activate <CODE>`（v0.12.0 兼容） |
| 激活（会话内）    | `/clawchat-activate <code>`                                   | `/clawchat-activate <CODE>`                                                               |
| 刷新凭据          | `openclaw channels login --channel openclaw-clawchat`         | 重新运行激活                                                                             |

---

## 5. 配置键交叉对照

同一概念，键名/位置/（偶尔）默认值不同。OpenClaw 键位于 `openclaw.json` 的
`channels.openclaw-clawchat.*` 下；Hermes 键位于 `config.yaml` 的
`platforms.clawchat.extra.*` 下（或 `CLAWCHAT_*` 环境变量），密钥除外 ——
密钥仅在 `.env`。

| 概念                 | OpenClaw 键               | Hermes 键 / 环境变量                          | 默认值                        |
| -------------------- | ------------------------- | --------------------------------------------- | ----------------------------- |
| WebSocket URL        | `websocketUrl`            | `websocket_url` / `CLAWCHAT_WEBSOCKET_URL`    | `wss://app.clawling.com/ws`   |
| REST base URL        | `baseUrl`                 | `base_url` / `CLAWCHAT_BASE_URL`              | `https://app.clawling.com`    |
| Access token         | `token`                   | `.env` `CLAWCHAT_TOKEN`                        | —（由激活写入）               |
| Refresh token        | `refreshToken`            | `.env` `CLAWCHAT_REFRESH_TOKEN`               | —（由激活写入）               |
| Agent id             | `agentId`                 | `agent_id` / `CLAWCHAT_AGENT_ID`              | JWT `aid` claim               |
| User id              | `userId`                  | `user_id` / `CLAWCHAT_USER_ID`                | `""`                          |
| Owner user id        | `ownerUserId`             | `owner_user_id` / `CLAWCHAT_OWNER_USER_ID`    | `""`                          |
| 回复模式             | `replyMode`               | `reply_mode` / `CLAWCHAT_REPLY_MODE`          | `stream`                      |
| 群组模式             | `groupMode`               | `group_mode` / `CLAWCHAT_GROUP_MODE`          | `all`                         |
| 群组命令模式         | `groupCommandMode`        | `group_command_mode` / `CLAWCHAT_GROUP_COMMAND_MODE` | `owner`                |
| 转发思考内容         | `forwardThinking`         | `show_think_output`                           | ⚠️ **`true`（OC）** vs **`false`（Hermes）** |
| 转发工具调用         | `forwardToolCalls`        | `show_tools_output`                           | `false`                       |
| 富交互               | `richInteractions`        | `enable_rich_interactions`                    | `false`                       |
| 流式 flush 窗口      | `stream.flushIntervalMs`  | `stream.flush_interval_ms`                    | `250`                         |
| 流式最小分片         | `stream.minChunkChars`    | `stream.min_chunk_chars`                      | `40`                          |
| 流式最大缓冲         | `stream.maxBufferChars`   | `stream.max_buffer_chars`                     | `2000`                        |
| 重连初始延迟         | `reconnect.initialDelay`  | `reconnect_initial_delay_ms`                  | `500`                         |
| 重连最大延迟         | `reconnect.maxDelay`      | `reconnect_max_delay_ms`                      | `15000`                       |
| 重连抖动             | `reconnect.jitterRatio`   | `reconnect_jitter_ratio`                      | `0.3`                         |
| 重连最大次数         | `reconnect.maxRetries`    | `reconnect_max_retries`                       | `∞`                           |
| 心跳间隔             | `heartbeat.interval`      | `heartbeat_interval_ms`                       | `20000`                       |
| 心跳超时             | `heartbeat.timeout`       | `heartbeat_timeout_ms`                        | `10000`                       |
| Ack 超时             | `ack.timeout`             | `ack_timeout_ms`                              | `15000`                       |
| Ack 超时自动重发     | `ack.autoResendOnTimeout` | `ack_auto_resend_on_timeout`                  | `false`                       |
| 媒体本地根目录       | （运行时 allowed roots）  | `media_local_roots` / `CLAWCHAT_MEDIA_LOCAL_ROOTS` | 空                       |
| 按群覆盖             | `groups.<id>.{groupMode,groupCommandMode}` | `groups.<id>.{group_mode,group_command_mode}` | 继承顶层            |

> ⚠️ **默认值分歧：** 思考/推理内容的转发，OpenClaw 默认**开启**
> （`forwardThinking: true`），而 Hermes 默认**关闭**
> （`show_think_output: false`）。若想要开箱即用的一致冗长度，请显式设置它们。

---

## 6. 保持两者同步

因为它们把同一份契约实现了两遍，对齐是一项维护义务，而非自动成立。当你改动以下
任一项时，请**两个**插件都改（并在标注处先改上游所有者）：

1. **线路协议。** **先**改 `clawchat-msghub` 参考文档
   （`docs/features/msghub/protocol-v2-*.md`），再改
   `clawchat-plugin-openclaw/src/protocol.ts` + `inbound.ts` 与
   `clawchat-plugin-hermes-agent/clawchat_gateway/protocol.py` + `inbound.py`。
2. **工具集。** 保持这 22 个工具一致：
   `openclaw.plugin.json`（`contracts.tools`）+ `src/tools.ts` ↔
   `plugin.yaml`（`provides_tools`）+ `clawchat_gateway/plugin_tools.py`。
3. **提示词。** `prompts/platform.md`、`default-owner-behavior.md`、
   `default-group-bio.md` 在两个仓库中应保持等价。
4. **捆绑 skill。** `skills/clawchat/SKILL.md` 的指引应一致。
5. **memory 契约。** `owner.md` / `users/` / `groups/` 布局、memory 与 metadata
   工具的切分、以及可写 metadata 字段是共享的（权威说明位于
   `clawchat-plugin-openclaw/docs/clawchat-memory.md`）。
6. **连接默认值。** 重连 / 心跳 / ack / 流式默认值理应一致 —— 并留意 §5 中提到的
   `forwardThinking` 与 `show_think_output` 默认值分歧。

---

## 权威来源指引

| 主题                                    | 所在位置                                                              |
| --------------------------------------- | --------------------------------------------------------------------- |
| OpenClaw 插件参考（配置、工具、激活、流式、排障） | `clawchat-plugin-openclaw/docs/openclaw-clawchat.md` |
| OpenClaw 编码 agent 导览                | `clawchat-plugin-openclaw/AGENTS.md`                                        |
| 共享的 ClawChat memory 契约             | `clawchat-plugin-openclaw/docs/clawchat-memory.md`                           |
| Protocol v2 客户端集成（镜像）          | `clawchat-plugin-openclaw/docs/client-integration.md`                        |
| Hermes 集成面                           | `clawchat-plugin-hermes-agent/docs/architecture.md`                                |
| Hermes 配置（环境变量 + `config.yaml`） | `clawchat-plugin-hermes-agent/docs/configuration.md`                               |
| Hermes 工具目录                         | `clawchat-plugin-hermes-agent/docs/reference/tools.md`                             |
| Hermes 安装 + 激活                      | `clawchat-plugin-hermes-agent/docs/install.md`                                     |
| **权威线路协议**                        | `clawchat-msghub/clawchat-msghub/docs/features/msghub/protocol-v2-*.md`（所有者） |
