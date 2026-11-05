<!-- codex-external-window-routing v1 begin -->
### 外部窗口按用途分流

- Codex 自行发起的所有真实窗口，包括测试、输入探针、说明页和预览，默认属于 `automation`，只能使用用户设置的副屏，优先后台。不能因为打算给用户看就归为个人查看；用户同意测试或短暂前台也不等于同意主屏开窗。
- 只有用户本人点击“在 Finder 中显示”等查看入口，或明确要求在当前屏查看，才属于 `review` / `user`；使用打开前用户焦点窗口所在屏幕，不按鼠标停留位置或 macOS 主显示器判断。Agent 主动安排的手动测试不算这项授权。
- 轻量入口是 `hs._codexWindowGateway.open(intent, application, options)`，实现和说明在 `/Users/example/Documents/ChatGPT/修复computer use抢鼠标/`。不再加载旧的 Dock/菜单推测路由，不恢复或激活个人 Chrome 旧窗口。未登记的个人窗口保持原位。
- 主屏查看入口必须额外有 `userRequestedMain=true`，仅在上述明确授权确实存在时使用；不能为了模拟个人开窗自行填写。没有这项授权时，真实测试窗口一律使用 automation；个人开窗逻辑只在模拟环境检查。
- Chrome 先按工具文档连接、命名任务；从 management 读取当前窗口编号，再用 open("automation","chrome",{browserBaselineIDs={...}}) 获取当次请求。将 browser/chrome_work_window.mjs 去掉 export 后加载到 Computer Use，使用 createChromeFromGateway(browser,request,extensionInstanceId)，再将返回的 proof 交给 finishBrowser。浏览器编号与 macOS 原生窗口编号不可混用。只操作精确的新任务标签。
- Finder 使用 open("automation","finder",{directory=absoluteDirectory}) 新建目标屏窗口。不能使用会复用个人窗口的普通 open / open -R。权限拒绝或超时后先查明原因，不通过其他进程绕过，也不循环重试。
- Obsidian 使用 open("automation","obsidian",{protectedDirectories={...}}) 的独立后台副本，不再使用 allowForeground。它只创建自己的配置和空白库，不打开个人库，不改个人笔记或插件。等待 results[requestID].ok 及 backgroundBootstrapInstalled，再按准确 PID、原生窗口编号和返回的 workerApp 完整路径连接 Computer Use；不得用 md.obsidian 或应用名称连接个人实例。已实测后台启动、输入、后续新窗口及关闭；真实个人库和系统权限弹窗未验收。若没有后台副本或启动失败，停止并报告错误，不回退普通 Obsidian。使用真实库仍需另外明确任务范围。
- 用户已允许本轮必要的独立窗口测试和短暂前台测试，之后明确取消人工测试要求。此许可不推广到后续无关任务，也不允许主屏测试窗口。当前仍不得做个人笔记/插件性能测试。
- 全局安全暂停标记 codexComputerUseSafetySuspended=true 时不得自行恢复。副屏断开、关闭自动分配、归属不清或接口不支持时停止相应 GUI 步骤，不回退主屏，不移动旧个人窗口，不循环抢焦点。
- 这些是 Agent 调用约定，不是系统级强制拦截。旧脚本、普通 Dock/Spotlight、Codex 自带查看入口及任意其他软件尚不能声称全部完成验收。自动模拟个人开窗不等于本人实机验证；PiP 的旧位置规则不等于输入隔离。
<!-- codex-external-window-routing v1 end -->
