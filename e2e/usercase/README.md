# E2E 测试用例（usercase）

基于 [`../`](../) 的环境启动 runbook 之上的**具体端到端测试用例**：每个用例自动起一套真实环境、
跑一条完整业务链路、给出 PASS/FAIL 与用时。环境均为临时 / 用完即弃。

> 通用前置（kubeconfig / namespace / registry / LLM 网关）见 [`../README.md`](../README.md)。
> 凭据放 [`e2e/.env`](../.env.example)（已 .gitignore）。

## 用例索引

| 用例 | 脚本 | 验证内容 |
|------|------|----------|
| [`hermes-install-activate.md`](hermes-install-activate.md) | [`run-hermes-install-activate.sh`](run-hermes-install-activate.sh) | 起 hermes e2e 环境 → 申请连接码 → 发 prompt 让 agent 按 `install-dev.md` 安装并激活 clawchat 插件 → 连上 ClawChat。**安装+连接 3 分钟硬超时**，超时即中断返回结果。目标后端：test env（`company.newbaselab.com`）。 |

## 运行约定

- 脚本从 `e2e/.env` 读配置；先 `cp ../.env.example ../.env` 并填 `CLAWCHAT_JWT`。
- 退出码：`0`=PASS，`1`=FAIL/超时，`2`=配置/前置缺失。
- 默认 `KEEP=1` 跑完保留环境便于复查；`KEEP=0` 跑完彻底销毁。
