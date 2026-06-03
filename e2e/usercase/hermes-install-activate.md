# 用例：hermes agent 安装并激活 ClawChat 插件（端到端连接）

**目标**：验证「起一个全新的 hermes agent → 让它按 `install-dev.md` 安装 clawchat 插件 →
用连接码激活 → 真正连上 ClawChat」整条链路，且**安装 + 连接要尽量快，超过 3 分钟即中断并返回结果**。

对应脚本：[`run-hermes-install-activate.sh`](run-hermes-install-activate.sh)（落地了下面全部步骤）。

> **目标环境：test env（`company.newbaselab.com`）。** connect-code 签发、插件安装、
> 激活**必须是同一个后端**，否则激活会失败。`install-dev.md@dev` 默认就指向
> `company.newbaselab.com:39001-3`，因此「严格按 install-dev.md」与本用例的 test env 一致 ——
> 唯一区别：连接码从 `company.newbaselab.com:39001` 申请（而非 apifox 模板里的 `app.clawling.com`）。

---

## 前置条件

- `KUBECONFIG=~/.kube/dev.config`，namespace `joe-clawchat-dev`（详见 [`../hermes-agent-e2e.md`](../hermes-agent-e2e.md)）。
- `e2e/.env` 已创建（从 [`../.env.example`](../.env.example) 复制），填入：
  - `CLAWCHAT_JWT` —— 一个**已登录测试用户**的移动端 Bearer JWT（用于申请连接码）。
  - `LLM_API_KEY` —— clawling 网关 key（`sk-crawling-…`），agent 推理用；脚本经 Secret 注入容器。
  - 其余 host / tag / 超时项有默认值，按需覆盖。
- 本机 `curl`、`jq`，能访问 `company.newbaselab.com:39001`。
- **hermes 镜像内需有 `node`/`npx`** —— 插件安装走 `npx @clawling/clawchat-plugin-install-cli`。
  脚本会先 `command -v npx` 自检，缺失则直接判失败（需换镜像或改用预装插件）。

## 步骤（脚本自动执行）

1. **起 hermes e2e 环境镜像** —— 按 `../hermes-agent-e2e.md` 起 `hermes-agent-smoke`
   Deployment（local-path PVC + `securityContext` 10000 + `sleep infinity`，LLM 走内部
   clawling 网关）。等 `1/1 Running`。
2. **申请连接码** ——
   ```bash
   curl --location --request POST 'https://company.newbaselab.com:39001/v1/agents/connect-codes' \
     --header 'Authorization: Bearer <jwt_token>' \
     --header 'x-device-id: apifox' \
     --header 'Content-Type: application/json' \
     --data-raw '{"force": true}'
   ```
   从响应解析出连接码 `<code>`。
3. **发 prompt 驱动安装 + 激活**（通过 `hermes chat -q`）。install-dev.md 的 Hermes 路径已是
   **单条命令**：`npx … install --target hermes@… --activate <code>` 一次完成安装+激活（CLI 内联
   调 `hermes clawchat activate`），agent 只需跑这一条：
   > Strictly follow the instructions in the local file `/opt/data/install-dev.md` to install and activate the clawchat plugin for Hermes. The active code is `<code>`.

   **有界 turn + 失败重试**：实测真实「安装→激活→连上」链路只需 ~20s，端到端成败几乎全取决于
   弱模型/LLM 网关——后者偶发在「生成工具调用」时卡死，整个会话空转到超时、激活根本没发生。
   故脚本给每次 agent turn 一个较短预算（≤70s），turn 中只读轮询 `activations` 表；一旦凭据落库
   即收工。若 turn 卡死（进入 ~30s 仍零安装进展：连 npx/git 进程都没有）就提前止损，并在总预算内
   **重发 prompt 重试**（连接码未被用过时可安全重试；install 幂等）。这把对 LLM 抖动的免疫力拉满。
4. **拉起 gateway 并等连接** —— 激活只持久化凭据（`/opt/data/.env` 的 `CLAWCHAT_TOKEN` +
   `config.yaml` 的 `platforms.clawchat` + `clawchat.sqlite` 的 `activations`）；WebSocket 要靠长驻
   的 `hermes gateway` 进程才会建立。脚本在**确认激活后**（agent turn 已收掉，避免并发重启打断激活/
   抢 CPU）显式 `hermes gateway restart`（幂等），日志写到 `/opt/data/gateway.log`。

## 成功判定

在硬超时（默认 `TIMEOUT_SECONDS=180`，即 **3 分钟**，从步骤 3 发 prompt 起算）内观察到任一信号即 **PASS**：

- `/opt/data/gateway.log` 出现 `clawchat.ws event=handshake_ok`（WS 握手就绪，最可靠）；或
- `/opt/data/clawchat.sqlite` 的 `connections` 表存在 `state='ready'` 记录。

脚本会打印连接用时（`约 Ns ≤ 180s`）。

## 超时 / 中断

超过 3 分钟仍未连接 → **中断测试**：杀掉后台 agent turn，dump 诊断（`gateway.log` 末尾、
`activations`/`connections` 表、agent 输出末尾），返回非 0 退出码。其间若 agent turn 反复卡死，
脚本会在预算内重试若干次（见步骤 3）；只有重试也用尽预算才判失败。

## 运行

```bash
cd e2e/usercase
cp ../.env.example ../.env      # 然后编辑填入 CLAWCHAT_JWT
./run-hermes-install-activate.sh           # 跑完默认保留环境，便于复查
KEEP=0 ./run-hermes-install-activate.sh    # 跑完彻底销毁（删 Deployment/CM/PVC）
```

退出码：`0`=PASS，`1`=FAIL/超时，`2`=配置/前置缺失。

## 清理

默认保留环境（`KEEP=1`）。彻底销毁：

```bash
kubectl -n joe-clawchat-dev delete -f e2e/usercase/.hermes-agent-smoke.gen.yaml
# 或参见 ../hermes-agent-e2e.md「停止 / 清理」
```

## 已知假设（首跑请确认）

- **连接码字段名**：脚本按 `.code / .connect_code / .data.code / .data.connectCode` 兜底解析；
  若接口返回结构不同，按实际响应调整脚本中的 `jq` 取值。
- **镜像含 npx**：见前置条件；缺失则安装步骤无法进行。
- **模型执行力**：`deepseek-v4-flash` 经内部网关偶发在「生成工具调用」时卡死（实测：会话停在
  `preparing terminal…`、整轮空转、`activations=0`）。这是 LLM 基础设施抖动，非 CLI/文档问题；
  脚本以「有界 turn + 卡死早杀 + 重发 prompt 重试」消化它（见步骤 3）。单条 `install --activate`
  命令把激活收敛到一次工具调用，配合重试后实测 5/5 通过（约 48–158s）。
- **连接信号采集**：依赖 `hermes gateway` 把日志写到 `/opt/data/gateway.log` 且 `sqlite3` 可用；
  首跑若两路信号都拿不到但人工确认已连上，按实际信号微调轮询条件。
