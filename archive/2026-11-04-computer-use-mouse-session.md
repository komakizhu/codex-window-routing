# 2026-11-04 Computer Use 分流会话归档

## 会话总结

- 基于本地 `main` 提交 `86e93e4` 创建独立 worktree：
  `/Users/example/.codex/worktrees/computer-use-mouse-fix-2026-11-04/修复computer use抢鼠标`。
- 当前分支：`codex/fix-computer-use-mouse-2026-11-04`。当前 worktree 没有项目代码改动。
- 本次确认 Hammerspoon 运行时不依赖项目级 `AGENTS.md`：运行配置来自 `/Users/example/.hammerspoon/`，正式状态查询返回 `gatewayLoaded=true`、`gatewayReady=true`、`assignmentEnabled=true`、`safetySuspended=false`。
- 按用户授权，更新了全局 `/Users/example/.codex/AGENTS.md` 的窗口前台规则：Hammerspoon 分流状态完整有效时，已由 gateway 核验并落到副屏的 `automation` 新窗口可直接激活，不再要求用户批准；该文件不属于本仓库，因此不在本 commit 中。

## 资料清单

| 文件或目录 | 实际路径 | 与会话的关系 |
| --- | --- | --- |
| 项目规则 | `AGENTS.md` | 说明本项目的 Hammerspoon gateway、automation 副屏入口和验收边界；本次未修改。 |
| Hammerspoon 说明 | `hammerspoon/README.md` | 说明运行时由 Hammerspoon 管理，`AGENTS.md` 不是开关或前置条件。 |
| 开窗使用说明 | `hammerspoon/轻量开窗使用说明.md` | 记录 automation、review/user 和 Obsidian 后台副本的入口约束。 |
| 路由说明 | `routing/README.md` | 说明 Hook、CLI 和安装目录；全局 `AGENTS.md` 不是运行前提。 |
| 路由 CLI | `routing/window_cli.mjs` | 通过正式入口查询 gateway 状态和执行登记操作。 |
| 运行时入口 | `/Users/example/.hammerspoon/init.lua` | 当前 Hammerspoon 启动入口，加载 sidecar 和 window gateway。 |
| 运行时模块 | `/Users/example/.hammerspoon/computer_use_sidecar.lua`、`/Users/example/.hammerspoon/window_gateway.lua` | 实际执行副屏分流的 Lua 模块。 |
| 全局规则 | `/Users/example/.codex/AGENTS.md` | 本次已更新，但位于仓库外，不能由当前分支提交。 |

## 检查结果

- 当前分支在归档前无未提交项目改动。
- `node /Users/example/.codex/window-routing/current/routing/window_cli.mjs status` 查询成功。
- 之前完成的基线检查：routing 29 项、Obsidian 13 项、浏览器 16 项、配置 3 项、安全检查 104 项均通过；Lua 测试因环境未安装 `lua` 未运行。
