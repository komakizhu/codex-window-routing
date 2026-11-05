# Codex 副屏工作区

当前分流开关是 Hammerspoon：运行且自动分配开启时，Codex 新窗口走副屏入口；关闭、暂停、安全挂起或副屏不可用时，配套 Hook 放行 Codex 原有行为。Hook 由同一个安装器管理，`AGENTS.md` 不是开关或前置条件。既有验收记录见 [来源分流验收](test/窗口来源与主副屏分流验收.md)。

当前使用轻量入口：现有选屏/PiP 模块加 `window_gateway.lua`，不安装虚拟机或新的常驻应用。旧的 Dock/菜单推测逻辑和全局观察器不再自动加载。

Codex 自己创建的任务、测试、输入探针或预览都去配置的副屏。只有本人点击查看入口或明确要求当前屏查看，才允许走个人查看入口。不能因为“打算给用户看”而在主屏创建测试窗口。

使用方法、调用接口、开关和限制见 [轻量开窗使用说明](轻量开窗使用说明.md)。本轮实测和证据见 [轻量方案验收](test/轻量方案验收.md)。

## 开关和选屏

菜单栏 `CU副屏 ●` → `暂停自动分配` / `开启自动分配`。可以选择 `固定使用指定副屏`（按 UUID 保存），或 `跟随焦点，使用另一块屏`。不按鼠标经过或 macOS 主显示器判断。

暂停、目标屏幕断开、编号不明确或接口不可用时，Hook 不再拦截 Codex；恢复 Codex 原有行为。安全暂停标记不会由 Hook 或安装器自行解除。

## 当前使用边界

Chrome 和 Finder 的明确新窗口路径已做副屏后台实测。Obsidian 已改为独立后台副本，启动、输入、后续开窗及关闭见 [后台输入验收](test/Obsidian后台输入验收.md)。它使用自己的空白库，不代表真实个人笔记库或系统权限弹窗已经验收，也不允许修改个人笔记和插件。

配套 Hook 只约束支持的 Codex 工具路径，不接管个人 Dock/Spotlight；它不是系统级沙箱。个人普通开窗未实机验证。PiP 的旧规则保留，此前输入复查未通过，不能仅凭窗口位置声称输入隔离通过。

## 恢复

本轮回退使用 [安装器](../routing/install.mjs) 的 `--rollback`，传入安装器返回的备份 manifest，细节见 [安装与回退说明](../routing/README.md)。安装器不再改动全局 `AGENTS.md`；回退只处理它实际备份的 Hammerspoon 和 Hook 文件。

## 历史记录

- [旧 Chrome 连续任务验收](test/Chrome连接恢复与连续任务.md)
- [旧个人窗口分流记录](test/个人窗口分流验收.md)
- [旧 Obsidian / Finder 排查](test/Obsidian与Finder分流修复.md)
- [Obsidian 故障恢复](</Users/example/Documents/ChatGPT/修复computer use抢鼠标/hammerspoon/test/Obsidian故障恢复记录.md>)（原工作区资料，未纳入本分支）
- [HTML Tabs 修复与内存复查](</Users/example/Documents/ChatGPT/修复computer use抢鼠标/repairs/html-tabs/安装与内存复查.md>)（原工作区资料，未纳入本分支）

历史记录中的“当时暂停”“旧推测路由已加载”等状态不代表本轮状态。
