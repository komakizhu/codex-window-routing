# Chrome 后台必须位于副屏：补测和当前状态

> 后续进展：用户允许临时前台检查后，连接已恢复；保留工作窗的连续任务实测通过。当前状态见 [连接恢复与连续任务验收](Chrome连接恢复与连续任务.md)。本文保留当时的失败和部分验收记录。

日期：2026-10-31，Asia/Shanghai。本批改动尚未提交，现有产品版本仍为 0.1.0。

## 结论

**只完成了部分验收，不能说整个问题已经修好。** 本次通过了“Chrome 从关闭状态启动但不弹窗，再在固定副屏后台创建窗口”的测试；三个测试窗口均在目标副屏完成填写、点击和关闭。关闭最后一个测试窗口后，Chrome 的操作连接断开，尚未恢复。

用户报告的那一次 Chrome 留在主屏的操作，没有取得当时的创建记录，不能断言已经查明其唯一原因。上轮方案的两个缺口已确认：隐藏的内置浏览器没有接入副屏选择；测试未覆盖 Chrome 尚未运行的情况。

## 本次修改

- 后台和副屏必须同时满足。本机网页任务不再使用缺少选屏接口的内置浏览器，也不把“隐藏”当作“已在副屏”。
- 新增 Hammerspoon `prepareChrome()`：目标屏不可用时不启动；Chrome 未运行时使用 `open -g -a ... --args --no-startup-window` 先启动进程、不弹窗口；等待扩展连接后才由 Chrome 管理接口按位置新建后台窗口。短时间内重复调用不重复启动。
- 扩充专用 Chrome 开窗函数：操作前后检查所属窗口和位置，网页操作报错时也执行事后检查；偏位时只允许恢复明确属于任务、没有混入其他标签的窗口。同一目标反复偏位就停止；初次开窗位置不符、Chrome 取得前台或标签进入旧窗口时也停止。
- 保留用户当前的“固定 Sidecar Display (AirPlay)”设置；没有改回跟随焦点。

代码：[Lua 模块](../computer_use_sidecar.lua)、[Chrome 开窗与操作函数](../../browser/chrome_work_window.mjs)、[本项目调用规则](../../AGENTS.md)。没有修改其他聊天的全局规则或 Codex 内置开窗工具。

## 实机检查

| 检查 | 实际结果 |
|---|---|
| Chrome 未运行时启动 | 使用临时命令和实际安装的 `prepareChrome()` 分别检查。均先得到无窗口的 Chrome 进程，扩展连接随后出现；未观察到切走前台。正式入口退出码为 0。 |
| 固定副屏创建窗口 | 3/3 通过。浏览器窗口编号为 `2137711167`、`2137711211`、`2137711216`，对应观察到的系统窗口为 `376`、`387`、`396`。系统均报告位于 Sidecar UUID `532D7571-4385-4C76-AE82-83D54579002B`；浏览器均报告 `focused:false`。 |
| 网页填写、点击 | 3/3 通过。只操作本机独立测试页。每个窗口使用 `runOnSideScreen` 执行，并取得对应“已读取”的网页结果。 |
| 位置检查与恢复 | 在第三个专用窗口中，将位置向右调整 20 个坐标单位，仍保持在副屏内；检查函数将其恢复原位，保持 `focused:false`。没有故意把测试窗口放到用户主屏。跨屏偏位恢复只做了模拟测试。 |
| 前台与焦点 | 19 条事件和检查记录均保持原来的 Codex 窗口 `166` 和同一焦点元素；没有应用激活或 Codex 焦点切换事件。本轮起始元素为 `AXGroup`，不能将它写成聊天输入框光标或用户同时打字测试。用户鼠标位置中途改变，不据此判断输入冲突。 |
| 关闭窗口 | 系统确认三个测试窗口全部关闭。最后的浏览器查询出现 `native pipe closed before response`，扩展连接随后不再出现在工具列表中；不能把连接中断记为检查通过。 |
| 恢复连接 | 正常浏览器选择接口返回 `Browser is not available: chrome`。尝试无窗口启动参数没有取得恢复连接的证据。没有接管后来出现的非测试 Chrome 窗口。 |
| Hammerspoon 运行 | 排查期间曾发现主进程不在运行；没有取得对应的崩溃记录，原因未确定。已在后台重新打开，固定屏幕选项保留。不得声称长期稳定性通过。 |
| 显示截图 | Hammerspoon 没有屏幕录制授权。截图只得到桌面壁纸，不能作为窗口画面证据，也没有请求扩大此权限。位置验收依据系统窗口 UUID/坐标和 Chrome 窗口接口，不冒充截图验证。 |
| 清理 | 已关闭全部测试窗口，停止临时网页服务和临时焦点观察。后续出现的 Chrome 窗口不属于本测试，没有移动或关闭。 |

完整证据：[检查汇总](chrome-routing-results.json)、[正式入口及固定副屏测试记录](chrome-fixed-background.json)。记录不含个人网页标题、输入值或页面内容。

## 代码检查

- `node --test browser/chrome_work_window.test.mjs`：8/8 通过。检查准确新标签归属、错误位置停止、操作前后检查、网页操作失败后仍检查、单次恢复、拒绝移动混入个人标签的窗口等。失败分支为模拟检查，未操作真实个人窗口。
- Hammerspoon 模拟规则检查：12/12 通过。新增无窗口冷启动、重复调用去重、已有 Chrome 不重启、暂停/断屏/未安装时不启动等检查。
- 实际 Lua 模块已同步；没有改动 `init.lua`、用户选屏设置或 Chrome 启动偏好。

## 仍需完成

1. 恢复 Chrome 扩展的正常操作连接，再验收连续多次任务。现在没有连接就停止，不能通过普通启动、主屏窗口或反复抢焦点绕过去。
2. 判断 Hammerspoon 为什么停止；确认后再做长时间稳定性检查。
3. 其他聊天未统一接入本项目调用方式。原生应用输入隔离也未解决。本次成功的三个测试窗口不代表全部 Computer Use 已验收通过。

当前不建议将整个方案当成已经稳定的全自动隔离工具长期启用。

## 本次更新的撤销

更新前备份：[上轮模块](/Users/example/.hammerspoon/backups/computer_use_sidecar.lua.cold-start-20261031-091632.bak)。实际模块：[computer_use_sidecar.lua](/Users/example/.hammerspoon/computer_use_sidecar.lua)。

恢复本轮 Lua 更新可运行：

```bash
cp "/Users/example/.hammerspoon/backups/computer_use_sidecar.lua.cold-start-20261031-091632.bak" "/Users/example/.hammerspoon/computer_use_sidecar.lua"
/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs -t 30 -c 'dofile(hs.configdir .. "/computer_use_sidecar.lua")'
```

本项目的 Agent 规则和 Chrome 函数仍为未提交改动；撤销它们时仅处理本批文件，不重置其他工作。

## 官方依据

[Chromium 启动代码](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/chrome/browser/ui/startup/startup_browser_creator.cc) 明确处理 `--no-startup-window`，用于不创建初始浏览器窗口。[Chrome windows API](https://developer.chrome.com/docs/extensions/reference/api/windows) 提供位置参数及 `focused:false`。具体效果以上述本机检查为准。
