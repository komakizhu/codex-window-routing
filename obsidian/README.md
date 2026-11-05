# Obsidian 副屏后台副本

本任务分支的最新结果见 [来源分流验收](../hammerspoon/test/窗口来源与主副屏分流验收.md)：后台启动、暂停隐藏及显示器失效保护已验证，当前按用户要求重点验收窗口来源和主副屏。[原生输入复查](../hammerspoon/test/窗口持续保护与输入复查.md) 未通过，但不能据此否定 Codex 的后台独立光标能力。本分支现已按用户授权安装，新构建副本经实际入口后台启动验证通过；Codex 调用前 hook 已由用户信任，信任后的合法副本启动和准确归属核对也已通过。下面保留原部署原理和使用说明。

本机已部署。正常使用不需要重新安装、手动开窗或再启动一个常驻程序。Hammerspoon 收到任务请求时才启动独立副本，任务结束关闭自己的窗口和进程。

## 为什么这样修

原 Obsidian 在窗口准备完成时调用 `BrowserWindow.show()`，这会要求前台。Hammerspoon 事后改变位置解决不了这个原因。

本方案从 `/Applications/Obsidian.app` 制作单独的任务副本，在原程序加载前将它自己的 `show()` 改为官方的 `showInactive()`，并抑制程序主动发出的聚焦请求。它不会循环切回用户应用。APFS 写时复制共享未修改的数据块，没有虚拟机，也没有额外常驻服务。

构建产物是只读模板。每个任务启动时，Hammerspoon 都会为它做一份 APFS 写时复制副本，保留模板的签名和 Bundle ID，并用独立的完整 App 路径登记任务。这样两个聊天同时开任务时，各自都有明确的 Computer Use 连接路径。每个任务还有自己的空白库、配置、加密存储名称和 CLI socket；进程退出后只清理这次生成的 App 副本。它不注册为个人 Obsidian URL 的默认处理程序。原应用的程序文件、个人配置、笔记及插件均不用于写入。

官方依据：[窗口不激活显示](https://www.electronjs.org/docs/latest/api/base-window#winshowinactive)、[Electron 设置存储名称的实现](https://github.com/electron/electron/blob/v39.8.3/shell/browser/electron_browser_main_parts.cc)、[官方 asar 打包工具](https://github.com/electron/asar)。

项目版本以根目录 `VERSION` 为准，当前为 0.3.5；构建副本的 `CFBundleShortVersionString` 和 worker.json 的 `version` 一致。`sourceVersion` 与 `CodexObsidianSourceVersion` 单独保留官方 Obsidian 来源版本，原安装器 build number 保持不变。安装目录中的旧副本不因本地定稿而自动替换。

## 任务入口

```lua
local pending, err = hs._codexWindowGateway.open("automation", "obsidian", {
    protectedDirectories = { "/absolute/personal/vault" },
})
-- 异步检查 hs._codexWindowGateway.results[pending.requestID]
-- 结果 ok=true 且 backgroundBootstrapInstalled=true 后才继续。
-- pending.pid 是准确进程，result.windowId 是原生窗口编号。
-- Computer Use 必须使用 pending.workerApp 的完整路径连接。
```

不要调用 `cua.getApp("Obsidian")` 或 `cua.getApp("md.obsidian")`：它们可能连接到个人应用。不要复用历史 PID 或窗口编号。没有副屏、暂停、后台副本缺失或启动失败时，报告具体错误，不改用个人应用。

后续新窗口沿用本次任务启动时选择的副屏。屏幕布局发生变化后先停止当前 GUI 操作，再按入口重新取得位置；本方案不把任意原生点击都包装成持续的选屏检查。

本分支让原生窗口先隐藏创建，再检查准确显示器编号及边界。显示器变化或任务控制文件暂停时，副本隐藏自己的窗口并保持暂停，不会重新连接后自行显示。新入口和副本需要一起更新，协议不符时停止启动。

## 重建

只有需要重建副本时才使用；它不改动 `/Applications/Obsidian.app`。需要 Node 22.12 及以上、macOS 的 `codesign` 和支持写时复制的 APFS。

```bash
npm ci --ignore-scripts --prefix obsidian
node obsidian/build_worker.mjs "$HOME/.hammerspoon/codex-obsidian-worker"
```

也支持给构建命令第二个参数传入 `@electron/asar/lib/asar.js` 完整路径。当前将 4.3.1 固定为 routing 包的本地依赖，可执行 `node obsidian/build_worker.mjs 输出目录 routing/node_modules/@electron/asar/lib/asar.js`，不依赖临时 npm 缓存或全局工具。

构建脚本只在自己的新目录写入，逐字节核对原 loader 模块，更新副本的 asar 完整性信息并校验签名。仅给副本外层签名，不使用 `--deep`，不改原应用的签名或启动开关。构建检查失败不发布新的 worker.json。当前实测来源为 Obsidian 1.12.7 / Electron 39.8.3；后续更新需要重新验收。

## 开关与撤销

菜单栏 `CU副屏` 的暂停开关控制新任务入口；没有给独立副本设置登录自启动。关闭任务时只结束返回的准确任务 PID，不结束个人 Obsidian。

项目原有的一键整体恢复仍是 [恢复 Hammerspoon 配置](../hammerspoon/restore_hammerspoon_config.sh)。恢复会移除本项目加载入口和拥有明确标记的规则段；后台副本随后不再被调用。它保留副本与测试记录以便撤销，不删除用户数据。恢复脚本本轮只做语法检查，没有实际执行。

仅撤销此修复时，可在暂停入口后恢复本轮前保存的 `window_gateway.lua` 和规则段，按备份核对，避免覆盖以后改动。不要把旧入口的拒绝启动当作问题已修好。

## 已验证与限制

实际结果见 [后台输入验收](../hammerspoon/test/Obsidian后台输入验收.md)。启动、后台文字输入、后续独立窗口和关闭已测试。真实个人库、插件、系统授权弹窗、外部程序跳转与任意 Computer Use 调用尚不在这个结果内。这个方案提供已测试路径上的后台操作，不是系统级鼠标键盘隔离。
