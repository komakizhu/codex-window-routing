# Codex 窗口来源与主副屏分流

目标：Codex 创建的窗口通过登记入口落到配置副屏；用户从 Dock/Spotlight 自己打开的窗口不由本项目接管。统一调度的候选源码位于独立 worktree 的 `codex/fix-computer-use-mouse-2026-11-04` 分支；本分支 Hook 尚未安装，Hammerspoon 尚未重载，因此历史 [验收记录](../hammerspoon/test/窗口来源与主副屏分流验收.md) 不代表这份候选源码已在宿主通过实测。

`window_cli.mjs` 是 Hammerspoon 入口的结构化桥接。它只接收 JSON 数据，不执行传入的 Lua/AppleScript；Agent 只允许 automation。`guard.mjs` 是 Hammerspoon 安装器统一管理的 `PreToolUse` 和 `PostToolUse` 配套 Hook：前者检查开窗来源和已登记对象，后者复核原生 App 操作后的窗口归属。Hammerspoon 关闭、暂停、安全挂起、不可用或状态查询失败时，Hook 返回普通放行结果，Codex 保持原有行为；全局 `AGENTS.md` 不再是开关或安装前提。事后检查只能阻止错误结果继续传给脚本，不能撤销 App 已经执行的操作。

## 行为与范围

| 请求 | 处理 |
| --- | --- |
| Hammerspoon 就绪时的 `open /现有目录`，无其他命令或选项 | 改写成副屏 Finder 新任务窗口，保留准确目标目录 |
| Hammerspoon 就绪时静态的 `open -a`、`open -b` 或直接打开 `.app` | 改写成通用 App 登记请求；名称必须唯一，启动后核对实际 Bundle ID、PID、新窗口和副屏 |
| Hammerspoon 就绪时的 `open -R`、复杂 AppleScript / Hammerspoon 命令、直接运行 `.app` 内可执行文件 | 拒绝猜测性改写，提示使用结构化入口 |
| Hammerspoon 就绪时的原生 `cua.getApp(...)` | 只接受 gateway 返回的准确 Bundle ID 或完整 `.app` 路径；不按显示名称猜窗口。每次操作前后再核对 PID、窗口和副屏 |
| 已有个人 App 窗口或同名 App 实例仍在运行 | 可以登记并将新窗口放到副屏；Computer Use 不能按窗口号精确连接时，连接会被拒绝，不会挑选个人窗口 |
| Obsidian | 继续使用现有隔离 worker 和空白库；普通实例的空白库路径还没有实机验收，不能连接个人实例 |
| Mac 上的 iOS Wrapper App | 只有 AppKit 能从完整路径解析到唯一 `.app` 和 Bundle ID 时，才按该 macOS 宿主 App 登记；不能据此推断所有 iOS App 都可连接 |
| Simulator 内的 iOS App | 只有宿主能明确定位本次任务自己的 Simulator 设备和窗口时才可继续；客体 App PID 不当作 macOS 窗口身份。目前没有设备 UDID 和客体 Bundle ID 的连接适配，因此该路径明确不支持 |
| Hammerspoon 就绪时直接新建外部浏览器窗口、`tabs.new()`、普通 `createBrowserTab` | 拒绝；使用登记请求和原样 Chrome 帮助函数 |
| Hammerspoon 关闭、暂停、目标屏不可用或 Hook 连不上 | Hook 放行；Codex 沿用原有工具行为 |
| 用户 Dock/Spotlight 开窗 | 不接入、不猜归属、不移动；保持系统本身的开窗行为 |
| 其他应用的普通查看、浏览器页面操作、文件和代码检查 | 继续使用 Codex 原有权限检查 |

这不是 macOS 安全沙箱。任意已存在的脚本、交互式 shell 输入、工具自己的弹窗及特殊工具路径可能不在覆盖内。Codex 官方说明 Hook 错误或超时可能不阻止工具；当 Hammerspoon 自身不可用时，本 Hook 也会主动放行。它不依赖 `AGENTS.md` 决定是否生效。[官方 Hooks 说明](https://learn.chatgpt.com/docs/hooks)

代码检查器会区分普通对象方法与浏览器开窗方法。普通对象的方法（例如 `auditDataFactory.create()`）、隐藏 IAB 标签和用 Python heredoc 读取文件，均有对应的放行检查。Chrome、Finder、Obsidian 保留各自的内部适配；浏览器方法换个变量名，以及未引用 heredoc 中真正执行的开窗命令替换，也不会绕过入口。数组转换不能把来源不明的旧对象当作已登记任务。Terminal 作为普通 App 管理；终端里静态的 `open -a` / `open -b` 启动会改写成同一入口，交互式终端续写等未经过 Hook 的路径不保证被捕获。

个人窗口的“留主屏”在这里指不被 Codex 的规则挪到副屏，沿用用户当前正常开窗位置。macOS 本身对某个应用记忆的屏幕、用户主动拖动和应用自身行为不由本项目覆盖。未用 Agent 在主屏模拟个人开窗，也不声称完成用户本人 Dock/Spotlight 手测。

## 使用

在项目中先执行 `npm ci --ignore-scripts --prefix routing`；当前依赖已安装且固定版本。

```bash
node routing/window_cli.mjs status
node routing/window_cli.mjs open finder --directory /绝对目录
node routing/window_cli.mjs open app --application Telegram
node routing/window_cli.mjs open app --bundle-id com.apple.Safari
node routing/window_cli.mjs open obsidian --protected '["/个人库目录"]'
node routing/window_cli.mjs request --request 请求编号
```

通用 App 请求会先解析名称、Bundle ID 或完整 `.app` 路径，再通过 `NSWorkspace` 后台启动新的 App 实例。请求记录会给出 `appPath`、`bundleID`、PID、窗口号、副屏位置和 `connectionReady`。只有 `connectionReady=true` 时才可用返回的 Bundle ID 或完整 `appPath` 调用 `cua.getApp(...)`；不要把显示名称传给 `getApp`，以免同名安装造成误连。如果原来已有这个 App 的进程或窗口，Computer Use 无法按窗口号选择本次窗口，结果会明确标为不可连接。新 App 仍可按用户确认的规则在核验后激活或聚焦。

Mac 上的 iOS Wrapper 只有能解析成唯一 App 身份时才进入同一登记；Simulator 内的 iOS App 需要额外的设备 UDID 和客体 Bundle ID 适配。当前实现不声称已经能精确操作 Simulator 内的应用。

Chrome 先按 Computer Use 文档连接并命名会话，提前将帮助函数加载好，再读取 management 的现有窗口编号并申请本次登记。请求有效期为 90 秒，取得后应连续完成开窗和 proof 登记；不要在请求中间插入长篇加载或无关检查。过期时停止并关闭准确的新任务标签，重新取得请求，不能放宽过期检查。

```bash
node routing/window_cli.mjs open chrome --baseline '[现有窗口编号]' --extension 浏览器连接编号
```

将 `browser/chrome_work_window.mjs` 原文去掉行首 `export ` 后加载到 Computer Use。用本次完整请求 JSON 和连接编号字面值调用 `createChromeFromGateway`，将返回 proof 写为 JSON 后执行 `finish-browser --request 编号 --proof-file 文件`。只操作本次新标签，每组操作前后核对位置。hook 不接受动态请求变量或被改写的帮助函数。

关闭原生任务窗口需同时提供请求、PID、窗口编号；停止 Obsidian 需请求和准确 PID：

```bash
node routing/window_cli.mjs close-native --request 编号 --pid 进程号 --window 窗口号
node routing/window_cli.mjs stop-worker --request 编号 --pid 进程号
```

## 安装、信任与回退

`node routing/install.mjs` 只预检查，不改运行配置。`--apply` 才会复制根目录 VERSION、完整入口及本地依赖到 `~/.codex/window-routing/current/`，构建后台 Obsidian 工作副本，更新本项目三个 Hammerspoon 文件及 `~/.codex/hooks.json`，再完整重载 Hammerspoon 配置以清掉旧模块。若只是更新 Hook 配套脚本，可用同一个安装器的 `--apply-hook`：它只备份并替换 `guard.mjs`、`window_cli.mjs` 和 `hooks.json`，不构建 Obsidian 副本，也不重载 Hammerspoon。全局 `AGENTS.md` 不再由安装器修改或检查，也不是运行前提。安装不合并 main、不设置登录启动项、不关闭其他会话的测试进程，也不清理旧副本。现有文件有无法识别的修改时停止。

安装保留 Hammerspoon 的分流开关；安全暂停为 true 时不会解除暂停。完整安装前若有旧入口登记的任务副本运行，会停止安装，保护其监控；`--apply-hook` 仅更新 Hook 配套脚本，不触碰 Hammerspoon 运行模块。两种更新都会备份替换的文件，完整安装还会备份旧 current 目录，成功后返回备份 manifest 路径。回退使用 `node routing/install.mjs --rollback /返回的/manifest.json`，安装后的文件被其他工作再次修改时拒绝覆盖。旧版整体恢复脚本不认识新增 Hook，不应用它代替此次回退。

首次安装时 Codex 可能要求在 Settings > Hooks 或 CLI `/hooks` 审阅并信任 **检查 Codex 副屏开窗**。这是 Codex 的一次性安全审阅，不是日常开关；安装器不会绕过信任。之后用户只用 Hammerspoon 开启或暂停分流。重新安装会恢复这个配套 Hook 的启用状态，但不会改写 Codex 的信任记录或其他权限规则。

## 检查

`python3 hammerspoon/test/run_safety_checks.py` 运行 JS 和隔离 Lua 规则检查；`python3 -m unittest discover -s config -p 'test_*.py'` 检查全局规则迁移。真实窗口只通过独立源环境的 [验收入口](../hammerspoon/test/window_routing_acceptance.lua) 创建，使用自己的副本、空白库和自动收尾，不替换安装配置。通用 App 验收前，将候选 Swift 启动器编译到该入口 `runtimeRoot/home/.codex/window-routing/current/bin/native-app-launcher`，以便验收调用当前分支产物而不读取已安装版本。

`CODEX_WINDOW_GATEWAY_SCOPE=acceptance` 只供此测试使用：要求专门的测试命名空间已加载，缺失时直接失败，绝不回退真实入口。常规使用不要设置它。
