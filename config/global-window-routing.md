<!-- codex-external-window-routing v1 begin -->
### 外部窗口按用途分流

- 只有 Hammerspoon 状态为 `gatewayLoaded=true`、`gatewayReady=true`、`assignmentEnabled=true` 且 `safetySuspended=false` 时，Codex 新建窗口才走 `automation` 副屏入口。
- Hammerspoon 关闭、暂停、安全挂起、目标屏不可用或状态查询失败时，Hook 放行 Codex 原有行为，不因缺少本文件或 Hook 阻止 Codex。安全暂停标记 `codexComputerUseSafetySuspended=true` 不得自行解除。
- 只有分流状态正常开启时，下面的专用入口规则才适用：使用已安装的 `window_cli.mjs`，它调用 `hs._codexWindowGateway.open("automation",application,options)`。不要用普通 `open`、`open -R`、`osascript`、原生应用路径或 `cua.getApp("应用名称")` 启动个人应用。不要恢复旧 Dock/菜单推测路由，也不恢复或激活个人 Chrome 旧窗口。
- Chrome：按工具文档选择连接并命名任务，从 management 读取现有窗口编号。调用 `window_cli.mjs open chrome --baseline '[编号]' --extension 连接编号`。将 `~/.codex/window-routing/current/browser/chrome_work_window.mjs` 逐字加载进 Computer Use，仅移除行首 `export `；调用 `createChromeFromGateway(browser,完整请求JSON,连接编号)`，后两项使用本次返回的字面值。将返回的 proof 写成 JSON 文件，再调用 `window_cli.mjs finish-browser --request 请求编号 --proof-file 文件`。只操作本次精确的新标签，每组操作前后调用 `runOnSideScreen` 或 `verifyPlacement`；浏览器编号与原生窗口编号不可混用。
- Finder：调用 `window_cli.mjs open finder --directory /绝对目录`，只创建新任务窗口，不复用个人窗口。系统权限拒绝或超时后查明原因，不绕行重试。Finder 已在前台时，新建窗口可能改变它内部的焦点窗口；不能因此声称输入隔离通过。
- Obsidian：调用 `window_cli.mjs open obsidian --protected '[受保护目录]'`，仅使用新建空白库和独立副本。用 `request --request 请求编号` 等待 result.ok 和 backgroundBootstrapInstalled，再按返回的完整 workerApp 路径连接 Computer Use，核对准确 PID 和原生窗口编号。不得用 `md.obsidian` 或应用名称连接个人实例。副本缺失或失败就停止，不回退普通 Obsidian；不打开个人库、不改个人笔记或插件。使用真实库需另行明确操作范围。
- 用户自己从 Dock/Spotlight 打开的窗口不经过 Agent 入口，保持系统原有位置。只有用户本人点击查看入口或明确要求当前屏查看，才能使用 review/user 和 `userRequestedMain=true`；此时按打开前用户焦点窗口所在屏幕，不按鼠标位置或 macOS 主显示器判断。Agent 自动模拟不算个人手测许可。CLI 不提供 review/user 模式。
- `PreToolUse` Hook 由 Hammerspoon 安装器作为配套组件管理。它只在 Hammerspoon 实际运行且分流启用时拒绝常见的直接启动、未登记原生应用和原始浏览器开窗；单独打开目录可改写成副屏 Finder 新窗口。Hammerspoon 关闭或不可用时放行。它不监控个人 Dock/Spotlight，也不是操作系统级沙箱。任意旧脚本、专用工具例外、交互式 shell 和 Codex 自带查看入口不能声称已全部拦截。
- 用户本轮将验收重点收敛为来源与主副屏分流。Codex 官方支持后台独立光标；PiP 是查看浮窗，不能单凭浮窗位置推断输入隔离。本项目原生输入复查未通过，不据此断言平台没有后台光标，也不再推进虚拟机方案。不要求用户手动测试，不在主屏创建真实测试窗口。
<!-- codex-external-window-routing v1 end -->
