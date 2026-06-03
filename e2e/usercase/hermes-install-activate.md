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
3. **发 prompt 驱动安装 + 激活**（通过 `hermes chat -q`，agent loop 自己跑 npx 安装 +
   `hermes clawchat activate <code>`）：
   > Strictly follow the instruction from https://plugin.clawling.chat/clawchat/install-dev.md to install and activate clawchat plugin. The active code is `<code>`.
4. **拉起 gateway 并等连接** —— 激活只持久化凭据（`/opt/data/.env` 的 `CLAWCHAT_TOKEN` +
   `config.yaml` 的 `platforms.clawchat`）；WebSocket 要靠长驻的 `hermes gateway` 进程才会建立。
   脚本在凭据落盘后显式 `hermes gateway restart`（幂等），把日志写到 `/opt/data/gateway.log`。

## 成功判定

在硬超时（默认 `TIMEOUT_SECONDS=180`，即 **3 分钟**，从步骤 3 发 prompt 起算）内观察到任一信号即 **PASS**：

- `/opt/data/gateway.log` 出现 `clawchat.ws event=handshake_ok`（WS 握手就绪，最可靠）；或
- `/opt/data/clawchat.sqlite` 的 `connections` 表存在 `state='ready'` 记录。

脚本会打印连接用时（`约 Ns ≤ 180s`）。

## 超时 / 中断

超过 3 分钟仍未连接 → **中断测试**：杀掉后台 agent turn，dump 诊断（`gateway.log` 末尾、
`activations`/`connections` 表、agent 输出末尾），返回非 0 退出码。

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
- **模型执行力**：`deepseek-v4-flash` 需可靠跟随 install-dev.md 的多步指令完成安装+激活 ——
  这正是本用例要验证的点之一；若 agent 没按步骤跑，看 agent 输出末尾诊断。
- **连接信号采集**：依赖 `hermes gateway` 把日志写到 `/opt/data/gateway.log` 且 `sqlite3` 可用；
  首跑若两路信号都拿不到但人工确认已连上，按实际信号微调轮询条件。
