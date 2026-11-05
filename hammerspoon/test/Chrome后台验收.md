# Chrome 副屏后台开窗验收

> 本文是上一轮测试记录。用户随后明确要求后台窗口也必须在副屏；当前改动、冷启动补测和仍未解决的问题见 [Chrome 副屏补测](Chrome副屏补测.md)。内置隐藏浏览器已不再作为本机网页任务的首选。

检查日期：2026-10-31，Asia/Shanghai。本次改动尚未提交；产品现有版本为 0.1.0。

## 结论

**新的 Chrome 开窗路径实测通过：3 个测试窗口均直接出现在副屏，后台填写、点击和关闭期间，聊天框保持在同一个输入位置。** 旧 Chrome 窗口的位置没有变化。

这证明本次使用的浏览器路径有效，不能据此认定所有 Computer Use、原生应用或其他聊天的直接开窗方式都已修好。

## 原因和改动

原有 Hammerspoon 模块只移动 Codex 的 `Computer Use` 预览和控制窗，并不接管普通 Chrome。默认开窗没有同时指定位置和后台状态，就可能出现在用户工作的屏幕上。

本次增加：

- Hammerspoon 的只读 `newWindowPlacement()`：沿用菜单中“跟随焦点”或“固定副屏”的选择，返回当前目标 UUID 及可用位置。暂停、断屏、目标太小时不给出开窗位置。
- [Chrome 开窗函数](../../browser/chrome_work_window.mjs)：通过浏览器管理接口新建 `focused:false` 的普通窗口，从创建时就放到目标位置；仅绑定接口返回的新标签编号。编号不明或窗口不符合要求时停止，不猜旧窗口归属。
- [本项目的 Agent 规则](../../AGENTS.md)：后台优先；需要普通 Chrome 时使用上述入口，不直接激活 Chrome，不反复抢回聊天框焦点。

实际使用的是已连接的 Chrome 扩展，仍属于普通 Chrome 进程，并未创建另一个用户账户或操作系统。窗口归属依据本次创建操作返回的编号，不依赖窗口标题。

## 实机结果

| 项目 | 结果 | 证据 |
|---|---|---|
| 直接在副屏后台开窗 | 3/3 通过 | 浏览器窗口编号 `2137710889`、`2137710894`、`2137710899`；系统窗口编号 `24010`、`24015`、`24020` 均在 Sidecar UUID `532D7571-4385-4C76-AE82-83D54579002B`。 |
| 打开网页 | 通过 | 首个窗口打开公共示例页；随后全部使用本机独立测试页，不读取或修改用户网页。 |
| 后台输入和点击 | 3/3 通过 | 每个测试页填入独立测试文字并点击“检查测试文字”，网页返回对应的“已读取”内容。使用浏览器标签接口，没有发送全局键盘快捷键。 |
| 聊天框输入位置 | 两段观察均保持 | 共 17 条事件及检查记录中，前台始终为 Codex，焦点窗口始终为 `23638`，焦点元素始终是最初的同一个 `AXTextArea`（聊天输入框）。没有观察到应用激活事件或 Codex 焦点切换事件。 |
| 鼠标位置 | 检查记录中未变 | 所有记录位置相同；没有调用全局鼠标点击或焦点恢复。 |
| 原有 Chrome 窗口保护 | 通过 | 系统窗口 `23871` 的位置、大小、屏幕均保持一致；未操作其中的标签或个人数据。 |
| 关闭测试窗口 | 3/3 通过 | 通过准确标签绑定关闭；关闭后只剩原有 Chrome 窗口，聊天输入框仍保持焦点。 |
| 清理 | 完成 | 关闭三个测试窗口，停止临时本机网页服务和焦点观察；普通观察模式仍为关闭，副屏分配仍为开启、跟随焦点。 |

焦点证据同时检查了前台应用、具体窗口和具体输入元素；不再仅凭“前台仍是 Codex”判断输入没有被打断。记录不含输入值、个人网页内容或窗口标题。

- [汇总数据](chrome-background-results.json)
- [首次开窗、导航、填写和点击的原始检查记录](chrome-focus-initial.json)
- [专用函数开窗及关闭测试的原始检查记录](chrome-focus-helper.json)
- [临时焦点观察脚本](chrome_focus_audit.lua)
- [独立测试网页](background-browser.html)

测试页成功画面已在本次聊天工具结果中显示，没有另存为本地图片文件。

## 代码检查

- `node --test browser/chrome_work_window.test.mjs`：4/4 通过。覆盖准确新标签绑定、负坐标、暂停/断屏不创建、找不到标签不碰个人标签、意外聚焦或位置不符时停止。
- Hammerspoon 模拟选屏检查：10/10 通过，包含本次新增开窗坐标及暂停处理。模拟检查不操作真实窗口。
- 实际安装的 Lua 模块与项目源文件一致；没有修改 `init.lua` 或用户选屏设置。

## 尚未验证及当前限制

- 没有让用户一边实际打字一边完成长时间验收。此次检查验证的是聊天输入元素一直保持焦点，不能声称已验证任意输入法、网站和长期连续使用。
- 本次真实 Chrome 开窗使用“跟随焦点”模式。固定模式的坐标选择做了模拟检查，未新增固定模式下的真实 Chrome 开窗测试。
- 没有修改 Codex 内置 Chrome 工具；其他聊天或旧脚本直接启动 Chrome 仍可绕过本入口。本工作区已有调用规则，用户全局 `AGENTS.md` 没有改写。
- 原生应用的 Computer Use 仍可能改变系统输入焦点，本次没有修复或重新验收该问题。
- 没有新增 PiP 显示测试；原有 PiP 移动逻辑没有改动，也没有隐藏 PiP。
- 新窗口创建失败时会停止，而不是反复激活或挪动；若 Chrome 已创建但没有返回可靠编号，会保留该新窗口并报告，避免误关用户窗口。

## 部署和撤销

实际运行模块：[computer_use_sidecar.lua](/Users/example/.hammerspoon/computer_use_sidecar.lua)。更新前备份：[原模块](/Users/example/.hammerspoon/backups/computer_use_sidecar.lua.chrome-20261031-085447.bak)。

本次仅同步模块并在后台重新加载，未改登录启动配置。撤销本次 Lua 更新：

```bash
cp "/Users/example/.hammerspoon/backups/computer_use_sidecar.lua.chrome-20261031-085447.bak" "/Users/example/.hammerspoon/computer_use_sidecar.lua"
/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs -t 30 -c 'dofile(hs.configdir .. "/computer_use_sidecar.lua")'
```

若撤销整个 Chrome 路径，同时停止使用新增的 Chrome 开窗函数及本项目 Agent 规则。现有个人窗口不需要恢复位置。

## 官方依据

[Chrome windows API](https://developer.chrome.com/docs/extensions/reference/api/windows) 说明创建窗口可指定位置，并用 `focused:false` 创建非活动窗口。实际能力和坐标仍以上面的本机检查为准。
