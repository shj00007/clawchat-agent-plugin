# 用例：openclaw agent 对话式安装并激活 ClawChat 插件（端到端连接）

**目标**：尽量**复刻真实用户链路** —— 用户已配好 LLM key,并通过**对话式聊天**让 agent
自己按 `install-dev.md` 安装 + 激活 clawchat 插件,最终真正连上 ClawChat。**安装 + 连接
要在 3 分钟内完成,超时即中断并返回结果。** 对照 Hermes 版 [`hermes-install-activate.md`](hermes-install-activate.md)。

对应脚本：[`run-openclaw-install-activate.sh`](run-openclaw-install-activate.sh)。

> **目标环境：test env（`company.newbaselab.com`）。** connect-code 签发、插件安装、激活
> 必须同一后端。`install-dev.md@dev` 默认即指向 `company.newbaselab.com:39001-3`。

---

## 前置条件

- `KUBECONFIG=~/.kube/dev.config`,namespace `joe-clawchat-dev`(详见 [`../openclaw-agent-e2e.md`](../openclaw-agent-e2e.md))。
- `e2e/.env` 已创建并填入：
  - `CLAWCHAT_JWT` —— 一个**已登录测试用户**的移动端 Bearer JWT(申请连接码用)。
  - `LLM_API_KEY` —— clawling 网关 key(`sk-crawling-…`),agent 推理用;脚本经 Secret 注入。
  - 其余 host / tag / 超时项有默认值。
- 本机 `curl`、`jq`,能访问 `company.newbaselab.com:39001`。
- **openclaw 镜像内需有 `node`/`npx`**(插件安装走 `npx @clawling/clawchat-plugin-install-cli@dev`)。

## 与 Hermes 用例的关键差异

| 维度 | OpenClaw | Hermes |
|---|---|---|
| 对话式安装 | `node openclaw.mjs agent --local -m "…"`(走 agent loop) | `hermes chat -q "…"` |
| 安装步数 | **两步**:install(`--target openclaw@dev`) + 单独 activate(`openclaw channels add --token`) | 一步(`--activate` 内联) |
| 安装来源 | npm dist-tag `openclaw@dev` | git 分支 `hermes@…#dev` |
| 持久连接 | `node openclaw.mjs gateway`(镜像默认主进程) | `hermes gateway` daemon |
| 连接信号 | gateway stdout `clawchat.ws event=handshake_ok` | 同(gateway.log) / `connections.state=ready` |

## 步骤(脚本自动执行)

1. **起 openclaw e2e 环境**(teardown + up,全新 PVC)。**把 seed 配置改成贴近真实部署**:
   - **移除预置的 `channels.clawchat-plugin-openclaw` 块** —— 真实新装的 OpenClaw 没有它;留着会让
     `openclaw plugins install` 的 config 校验失败(`unknown channel id`)。安装过程会自己写回 channel。
   - **设 `gateway.mode=local`** —— 真实 gateway 部署在 onboarding 阶段已有它;smoke seed 因为只跑
     `agent --local` 而没写。这是**模拟真实部署**,不是绕过用户流程。
2. **申请连接码**:`POST $API_BASE/v1/agents/connect-codes`(JWT + `x-device-id`),取 `.data.code`。
3. **对话式安装 + 激活**:预取 `install-dev.md` 到 pod(curl -4,绕 IPv6 黑洞),发 prompt 让 agent
   读本地文件并执行 OpenClaw 路径的 step2 + step3。**有界 turn + 卡死早杀(40s)+ 预算内重发 prompt**
   (吸收 OpenClaw 首调偶发 ~2min terminated 的 LLM 抖动)。轮询 `openclaw.json` 的 channel `token`
   落库即视为激活完成。
4. **拉起 gateway**:`node openclaw.mjs gateway`(前台 + timeout,stdout 捕获到 host 临时文件),
   轮询握手。

## 成功判定

3 分钟硬超时(`TIMEOUT_SECONDS=180`,从步骤 3 发 prompt 起算)内,gateway 输出出现
`clawchat.ws event=handshake_ok` 即 **PASS**(脚本打印用时)。超时 → 杀后台进程、dump 诊断
(gateway 输出末尾、`openclaw.json` channel/gateway、`plugins list`、agent 输出末尾)、返回非 0。

## 运行

```bash
cd e2e/usercase
cp ../.env.example ../.env      # 填 CLAWCHAT_JWT、LLM_API_KEY
./run-openclaw-install-activate.sh           # 跑完默认保留环境
KEEP=0 ./run-openclaw-install-activate.sh    # 跑完彻底销毁(删 Deploy/CM/Secret/PVC)
```

退出码：`0`=PASS,`1`=FAIL/超时,`2`=配置/前置缺失。

## 已知假设(首跑请确认)

- **依赖 `clawchat-plugin-install-cli@dev` 含 install 顺序修正**(先 `plugins install` 再写 channel
  URLs)。旧版 cli 会在严格校验的宿主上因"先写 channel 配置"而失败。见
  [`docs/superpowers/specs/2026-06-09-openclaw-conversational-install-e2e-design.md`](../../docs/superpowers/specs/2026-06-09-openclaw-conversational-install-e2e-design.md)。
- **`openclaw@dev` 已发布**(npm dist-tag),且含目标改动(`cap_multi_device:false`、`replay.done`)。
- OpenClaw CLI agent(`openclaw agent --local`)能调用 shell 工具跑 `npx`/`openclaw` 命令(同 Hermes)。
- 模型抖动:`deepseek-v4-flash` 经内部网关偶发卡在生成工具调用;脚本以"有界 turn + 早杀 + 重发"消化。
