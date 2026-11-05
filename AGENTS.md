# 本项目的后台与副屏规则

用户已明确采用一个开关：Hammerspoon 正常运行且分流开启时，Codex 新窗口走副屏入口；Hammerspoon 关闭、暂停、挂起或不可用时，Hook 放行 Codex 原有行为。Hook 是 Hammerspoon 的配套组件，不由本文件决定运行状态；本文件不是开关或前置条件。

不修改个人笔记、插件或已有窗口。Obsidian 工厂只使用新建的空白测试库和独立配置；当前正常实例不得关闭或重启。不得恢复个人库性能测试。

## 唯一新入口

- 仅在 Hammerspoon 状态报告 `gatewayLoaded=true`、`gatewayReady=true`、`assignmentEnabled=true` 且 `safetySuspended=false` 时，使用 `hs._codexWindowGateway.open(intent, application, options)`。`application` 当前为 chrome / finder / obsidian。旧 `external_window_router.lua` 不再加载。
- Hammerspoon 分流启用时默认 `automation`。只有用户本人点击查看入口或明确要求当前屏查看，才可使用 review / user 并提供 `userRequestedMain=true`；不能为了测试自行提供这个许可。用户焦点屏幕不依据鼠标位置或 macOS 主显示器判断。
- Chrome：先按工具文档选择连接、命名会话，读取 management.windows.getAll({populate:false}) 的编号。用 open("automation","chrome",{browserBaselineIDs={...}}) 得到请求，再调用 browser/chrome_work_window.mjs 的 createChromeFromGateway，最后将 proof 交给 finishBrowser。只操作当次明确返回的新标签；不要通过原生 getApp 或 tabs.new 绕开位置检查。任务页保持原帮助函数的前后位置检查。
- Finder：open("automation","finder",{directory=absoluteDirectory}) 创建精确的新窗口。不使用普通 open / open -R，不复用个人窗口。系统权限未实际生效时停止对应 GUI 步骤。
- Obsidian：在 Hammerspoon 分流启用时，open("automation","obsidian",{protectedDirectories={...}}) 启动独立后台副本，不再填写 allowForeground。仅使用它创建的配置及空白库；等待 results[requestID].ok 和 backgroundBootstrapInstalled 后，按准确 PID、原生窗口编号及返回的 workerApp 完整路径连接 Computer Use。不能用 md.obsidian 或应用名称接管个人实例。缺少副本、屏幕或启动失败时报告实际问题，不绕过 Hammerspoon 入口。
- Hammerspoon 关闭、暂停、安全挂起、目标屏不可用或状态查询失败时，不因分流 Hook 拒绝 Codex 调用；恢复 Codex 正常工具行为。安全暂停标记为 true 时不自行解除。

## 验收边界

真实自动开窗、纯模拟的个人开窗规则、用户本人普通 Dock/Spotlight 操作要分开报告。用户不愿手测时不得伪造人工验收。不得为测试个人路径而自行在主屏开真实窗口。

配置、入口和限制见 [轻量开窗使用说明](hammerspoon/轻量开窗使用说明.md)。Obsidian 后台修复以 [后台输入验收](hammerspoon/test/Obsidian后台输入验收.md) 为准，其他旧报告保留历史结果。文件/后台任务优先；输入保护不能仅凭窗口位置宣称通过。
