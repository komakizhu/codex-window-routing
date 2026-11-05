-- Keep Codex's observed Computer Use preview and controls on either the display
-- opposite the focused window, or a user-selected display remembered by UUID.
-- Neither mode uses macOS's primary-display flag or the mouse position.
-- This module never activates or raises windows.
local CODEX_BUNDLE_ID = "com.openai.codex"
local WINDOW_TITLES = {
    ["Computer Use"] = true,
    ["Computer Use Controls"] = true,
}
local SETTINGS_KEY = "codexComputerUseSidecarEnabled"
local PLACEMENT_SETTINGS_KEY = "codexComputerUseSidecarPlacement"
local CHROME_WORKSPACE_KEY = "codexChromeSideWorkspace"
local MODE_FOCUS = "opposite_focus"
local MODE_FIXED = "fixed_screen"
local LOG_PATH = hs.configdir .. "/computer-use-sidecar.jsonl"
local MOVE_DEBOUNCE_SECONDS = 0.12
local MOVE_BUDGET_SECONDS = 5
local MAX_MOVE_CALLS_PER_BUDGET = 4

hs._codexComputerUseSidecar = hs._codexComputerUseSidecar or {}
local runtime = hs._codexComputerUseSidecar
local function assignmentAllowed()
    return runtime.enabled==true and hs.settings.get("codexComputerUseSafetySuspended")~=true
end
runtime.pending = runtime.pending or {}
runtime.moveBudget = runtime.moveBudget or {}
runtime.targetUnavailableLogged = runtime.targetUnavailableLogged or {}

local savedPlacement = hs.settings.get(PLACEMENT_SETTINGS_KEY)
if type(savedPlacement) ~= "table" then savedPlacement = {} end
runtime.placement = {
    mode = savedPlacement.mode == MODE_FIXED and MODE_FIXED or MODE_FOCUS,
    fixedScreenUUID = type(savedPlacement.fixedScreenUUID) == "string"
        and savedPlacement.fixedScreenUUID ~= "" and savedPlacement.fixedScreenUUID or nil,
    fixedScreenName = type(savedPlacement.fixedScreenName) == "string"
        and savedPlacement.fixedScreenName or nil,
}

local function appInfo(app)
    if not app then return nil end
    return {
        bundleID = app:bundleID(),
        pid = app:pid(),
    }
end

local function frameInfo(window)
    local frame = window and window:frame()
    if not frame then return nil end
    return { x = frame.x, y = frame.y, w = frame.w, h = frame.h }
end

local function screenUUID(window)
    local screen = window and window:screen()
    return screen and screen:getUUID() or nil
end

local function focusedWindow()
    local frontmost = hs.application.frontmostApplication()
    if not frontmost then return nil end
    local window = frontmost:focusedWindow()
    if window then return window end

    -- The global AX-focused flag can linger on a window in a background app.
    -- Only accept it as a fallback when it belongs to the frontmost app.
    window = hs.window.focusedWindow()
    local owner = window and window:application()
    if owner and owner:pid() == frontmost:pid() then return window end
    return nil
end

local function oppositeScreenForFocusUUID(focusedUUID, screens)
    screens = screens or hs.screen.allScreens()
    if #screens ~= 2 then return nil, "requires_exactly_two_screens", #screens end
    if not focusedUUID then return nil, "focused_screen_unavailable", #screens end

    local focusedScreenFound = false
    local opposite = nil
    for _, screen in ipairs(screens) do
        if screen:getUUID() == focusedUUID then
            focusedScreenFound = true
        else
            opposite = screen
        end
    end
    if not focusedScreenFound then return nil, "focused_screen_not_connected", #screens end
    if not opposite then return nil, "opposite_screen_unavailable", #screens end
    return opposite, nil, #screens
end

local function fixedScreen(screens)
    local uuid = runtime.placement.fixedScreenUUID
    if not uuid then return nil, "fixed_screen_not_configured" end
    for _, screen in ipairs(screens) do
        if screen:getUUID() == uuid then return screen end
    end
    return nil, "fixed_screen_not_connected"
end

local function placementContext()
    local window = focusedWindow()
    local screens = hs.screen.allScreens()
    local focusedScreen = window and window:screen() or nil
    if runtime.placement.mode == MODE_FIXED then
        local target, reason = fixedScreen(screens)
        return target, focusedScreen, window, reason, #screens
    end
    if not window then
        return nil, nil, nil, "focused_window_unavailable", #screens
    end
    if not focusedScreen then
        return nil, nil, window, "focused_screen_unavailable", #screens
    end
    local target, reason, screenCount = oppositeScreenForFocusUUID(focusedScreen:getUUID(), screens)
    return target, focusedScreen, window, reason, screenCount
end

local function placementSnapshot()
    local target, focusedScreen, window, reason, screenCount = placementContext()
    return {
        rule = runtime.placement.mode == MODE_FIXED
            and "screen_fixed_by_uuid" or "screen_opposite_focused_window",
        placementMode = runtime.placement.mode,
        fixedScreenUUID = runtime.placement.fixedScreenUUID,
        fixedScreenName = runtime.placement.fixedScreenName,
        screenCount = screenCount,
        focusedWindowId = window and window:id() or nil,
        focusedScreenUUID = focusedScreen and focusedScreen:getUUID() or nil,
        targetScreenUUID = target and target:getUUID() or nil,
        targetScreenName = target and target:name() or nil,
        reason = reason,
    }
end

-- Read-only diagnostics used by the menu and acceptance checks.
runtime.placementSnapshot = placementSnapshot
-- A caller opening its own browser window can place it correctly from the
-- beginning. This only supplies bounds; it never claims existing app windows.
runtime.newWindowPlacement = function()
    local snapshot = placementSnapshot()
    snapshot.intent = "automation"
    snapshot.enabled = assignmentAllowed()
    snapshot.chromeWorkspace = runtime.chromeWorkspaceRecord and runtime.chromeWorkspaceRecord() or nil
    if not snapshot.enabled then
        snapshot.reason = "auto_assignment_paused"
        return snapshot
    end
    if not snapshot.targetScreenUUID then return snapshot end
    local target
    for _, screen in ipairs(hs.screen.allScreens()) do
        if screen:getUUID() == snapshot.targetScreenUUID then target = screen; break end
    end
    if not target then snapshot.reason = "target_screen_not_connected"; return snapshot end
    local frame = target:frame()
    if frame.w < 500 or frame.h < 400 then
        snapshot.reason = "target_screen_too_small"
        return snapshot
    end
    snapshot.bounds = {
        left = math.floor(frame.x + 40), top = math.floor(frame.y + 40),
        width = math.floor(math.min(1100, frame.w - 80)),
        height = math.floor(math.min(800, frame.h - 80)),
        focused = false, state = "normal",
    }
    return snapshot
end

-- Capture this BEFORE opening an external viewer. Human review follows the
-- current focused window's screen, independently of the fixed automation screen.
runtime.placementForIntent = function(intent)
    if intent == "automation" then return runtime.newWindowPlacement() end
    assert(intent == "review" or intent == "user", "unknown opening intent")
    local window = focusedWindow()
    local target = window and window:screen()
    local snapshot = { intent = intent, enabled = assignmentAllowed(),
        focusedWindowId = window and window:id(),
        targetScreenUUID = target and target:getUUID(),
        targetScreenName = target and target:name() }
    if not snapshot.enabled then snapshot.reason = "auto_assignment_paused"; return snapshot end
    if not target then snapshot.reason = "focused_screen_unavailable"; return snapshot end
    local frame = target:frame()
    snapshot.bounds = { left = math.floor(frame.x + 40), top = math.floor(frame.y + 40),
        width = math.floor(math.min(1100, frame.w - 80)),
        height = math.floor(math.min(800, frame.h - 80)), focused = false, state = "normal" }
    return snapshot
end

runtime.chromeWorkspaceRecord = function()
    local record = hs.settings.get(CHROME_WORKSPACE_KEY)
    local app = hs.application.get("com.google.Chrome")
    if type(record) == "table" and app and record.pid == app:pid() then return record end
    return nil
end
runtime.rememberChromeWorkspace = function(record)
    assert(type(record) == "table", "workspace record required")
    for _, field in ipairs({ "windowId", "tabId", "groupId" }) do
        assert(type(record[field]) == "number" and record[field] >= 0
            and record[field] % 1 == 0, "invalid workspace identifier")
    end
    assert(type(record.extensionInstanceId) == "string" and record.extensionInstanceId ~= "", "missing Chrome instance")
    local app = assert(hs.application.get("com.google.Chrome"), "Chrome is not running")
    local saved = { pid = app:pid(), windowId = record.windowId, tabId = record.tabId,
        groupId = record.groupId, extensionInstanceId = record.extensionInstanceId }
    hs.settings.set(CHROME_WORKSPACE_KEY, saved)
    return saved
end
runtime.oppositeScreenUUIDForFocusUUID = function(uuid)
    local target, reason, screenCount = oppositeScreenForFocusUUID(uuid)
    return {
        rule = "screen_opposite_focused_window",
        screenCount = screenCount,
        focusedScreenUUID = uuid,
        targetScreenUUID = target and target:getUUID() or nil,
        targetScreenName = target and target:name() or nil,
        reason = reason,
    }
end

local function append(record)
    local frontmost = hs.application.frontmostApplication()
    local mouse = hs.mouse.absolutePosition()
    record.timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
    record.epochSeconds = hs.timer.secondsSinceEpoch()
    record.placementMode = record.placementMode or runtime.placement.mode
    record.fixedScreenUUID = runtime.placement.fixedScreenUUID
    record.frontmostBundleID = frontmost and frontmost:bundleID() or nil
    record.mousePosition = mouse and { x = mouse.x, y = mouse.y } or nil

    local ok, encoded = pcall(hs.json.encode, record)
    if not ok or type(encoded) ~= "string" then
        hs.printf("computer-use-sidecar: JSON encode failed: %s", tostring(encoded))
        return
    end
    local file, err = io.open(LOG_PATH, "a")
    if not file then
        hs.printf("computer-use-sidecar: cannot append log: %s", tostring(err))
        return
    end
    file:write(encoded, "\n")
    file:flush()
    file:close()
end

-- Start only the browser process. The first work window is created later by
-- Chrome's documented management API, with explicit inactive side-screen bounds.
-- A normal app launch would create a window before that API can position it.
runtime.prepareChrome = function()
    local placement = runtime.newWindowPlacement()
    if placement.reason or not placement.bounds then return placement end
    local app = hs.application.get("com.google.Chrome")
    if app then
        placement.chromeState = "running"
        placement.chromePID = app:pid()
        return placement
    end
    local path = hs.application.pathForBundleID("com.google.Chrome")
    if not path then
        placement.reason = "chrome_not_installed"
        return placement
    end
    local previous = runtime.chromeLaunch
    if previous and hs.timer.secondsSinceEpoch() - previous.requestedAt < 15 then
        placement.chromeState = previous.exitCode and previous.exitCode ~= 0
            and "failed" or "starting"
        if placement.chromeState == "failed" then placement.reason = "chrome_background_start_failed" end
        return placement
    end
    local launch = { requestedAt = hs.timer.secondsSinceEpoch() }
    runtime.chromeLaunch = launch
    runtime.chromeLaunchTask = hs.task.new("/usr/bin/open", function(code, _, err)
        launch.exitCode = code
        append({ type = "chrome_background_start_result", exitCode = code,
            error = code ~= 0 and err or nil })
    end, { "-g", "-a", path, "--args", "--no-startup-window" })
    if not runtime.chromeLaunchTask or not runtime.chromeLaunchTask:start() then
        launch.exitCode = -1
        placement.reason = "chrome_background_start_failed"
        placement.chromeState = "failed"
    else
        placement.chromeState = "starting"
    end
    append({ type = "chrome_background_start_requested", state = placement.chromeState,
        targetScreenUUID = placement.targetScreenUUID })
    return placement
end

local function eligible(window)
    if not window then return false end
    local app = window:application()
    if not app or app:bundleID() ~= CODEX_BUNDLE_ID then return false end
    local title = window:title()
    if not WINDOW_TITLES[title] then return false end
    return window:role() == "AXWindow" and window:subrole() == "AXSystemDialog"
end

local function moveWindow(window, event)
    if not assignmentAllowed() or not eligible(window) then return end
    local id = tostring(window:id())
    if runtime.pending[id] then return end

    runtime.pending[id] = true
    hs.timer.doAfter(MOVE_DEBOUNCE_SECONDS, function()
        if not assignmentAllowed() then runtime.pending[id]=nil;return end
        local current = hs.window.get(tonumber(id))
        if not current or not eligible(current) then
            runtime.pending[id] = nil
            return
        end
        local target, focusedScreen, activeWindow, targetReason, screenCount = placementContext()
        if not target then
            runtime.pending[id] = nil
            if runtime.targetUnavailableLogged[id] ~= targetReason then
                runtime.targetUnavailableLogged[id] = targetReason or "unknown"
                append({
                    type = "move_skipped",
                    reason = targetReason or "opposite_screen_unavailable",
                    event = event,
                    windowId = current:id(),
                    title = current:title(),
                    app = appInfo(current:application()),
                    beforeScreenUUID = screenUUID(current),
                    focusedWindowId = activeWindow and activeWindow:id() or nil,
                    focusedScreenUUID = focusedScreen and focusedScreen:getUUID() or nil,
                    screenCount = screenCount,
                    beforeFrame = frameInfo(current),
                })
            end
            return
        end
        local targetUUID = target:getUUID()
        local currentScreen = screenUUID(current)
        runtime.targetUnavailableLogged[id] = nil
        if currentScreen == targetUUID then
            runtime.pending[id] = nil
            return
        end

        local now = hs.timer.secondsSinceEpoch()
        local budget = runtime.moveBudget[id]
        if not budget or now - budget.startedAt > MOVE_BUDGET_SECONDS then
            budget = { startedAt = now, count = 0 }
            runtime.moveBudget[id] = budget
        end
        if budget.count >= MAX_MOVE_CALLS_PER_BUDGET then
            runtime.pending[id] = nil
            append({
                type = "move_suppressed",
                reason = "repeat_move_guard",
                event = event,
                windowId = current:id(),
                title = current:title(),
                app = appInfo(current:application()),
                screenUUID = currentScreen,
                targetScreenUUID = targetUUID,
                attemptsInWindow = budget.count,
                budgetSeconds = MOVE_BUDGET_SECONDS,
            })
            return
        end
        budget.count = budget.count + 1

        local frontmostBefore = hs.application.frontmostApplication()
        local mouseBefore = hs.mouse.absolutePosition()
        local before = {
            placementMode = runtime.placement.mode,
            screenUUID = currentScreen,
            frame = frameInfo(current),
            focusedWindowId = activeWindow and activeWindow:id() or nil,
            focusedScreenUUID = focusedScreen and focusedScreen:getUUID() or nil,
            targetScreenUUID = targetUUID,
            frontmostBundleID = frontmostBefore and frontmostBefore:bundleID() or nil,
            mousePosition = mouseBefore and { x = mouseBefore.x, y = mouseBefore.y } or nil,
        }
        local ok, err = pcall(function()
            current:moveToScreen(target, true, true, 0)
        end)
        hs.timer.doAfter(0.4, function()
            if not assignmentAllowed() then runtime.pending[id]=nil;return end
            local after = hs.window.get(tonumber(id))
            local afterUUID = after and screenUUID(after) or nil
            append({
                type = "move_result",
                event = event,
                windowId = tonumber(id),
                title = after and after:title() or current:title(),
                app = appInfo(after and after:application() or current:application()),
                before = before,
                afterScreenUUID = afterUUID,
                targetScreenUUID = targetUUID,
                afterFrame = frameInfo(after),
                moveCallSucceeded = ok,
                moveError = err and tostring(err) or nil,
                verified = ok and afterUUID == targetUUID,
            })
            runtime.pending[id] = nil
            if assignmentAllowed() and after and eligible(after) then
                local latestTarget = placementContext()
                if latestTarget and afterUUID ~= latestTarget:getUUID() then
                    moveWindow(after, "placement_changed_during_move")
                end
            end
        end)
    end)
end

local function reconcileWindows(event)
    if not assignmentAllowed() or not runtime.filter then return end
    for _, window in ipairs(runtime.filter:getWindows()) do
        moveWindow(window, event)
    end
end

local function scheduleReconcile(event)
    if not assignmentAllowed() then return end
    if runtime.reconcileTimer then runtime.reconcileTimer:stop() end
    runtime.reconcileTimer = hs.timer.doAfter(0.08, function()
        runtime.reconcileTimer = nil
        reconcileWindows(event)
    end)
end

local function stopWatcher()
    if runtime.filter then
        runtime.filter:unsubscribeAll()
        runtime.filter = nil
    end
    if runtime.screenWatcher then
        runtime.screenWatcher:stop()
        runtime.screenWatcher = nil
    end
    if runtime.focusFilter then
        runtime.focusFilter:unsubscribeAll()
        runtime.focusFilter = nil
    end
    if runtime.applicationWatcher then
        runtime.applicationWatcher:stop()
        runtime.applicationWatcher = nil
    end
    if runtime.reconcileTimer then
        runtime.reconcileTimer:stop()
        runtime.reconcileTimer = nil
    end
end

local function startWatcher()
    if not assignmentAllowed() then return end
    if runtime.filter then return end
    -- Only subscribe to visible ChatGPT windows. Eligibility below additionally
    -- checks Codex's bundle ID, exact observed title, role, and subrole.
    local filter = hs.window.filter.new(false):setAppFilter("ChatGPT", {
        visible = true,
        allowRoles = "*",
    })
    filter:subscribe({
        [hs.window.filter.windowCreated] = function(window) moveWindow(window, "windowCreated") end,
        [hs.window.filter.windowMoved] = function(window) moveWindow(window, "windowMoved") end,
        [hs.window.filter.windowOnScreen] = function(window) moveWindow(window, "windowOnScreen") end,
        [hs.window.filter.windowTitleChanged] = function(window) moveWindow(window, "windowTitleChanged") end,
    })
    runtime.filter = filter

    runtime.screenWatcher = hs.screen.watcher.new(function()
        local placement = placementSnapshot()
        placement.type = "display_change"
        append(placement)
        reconcileWindows("display_change")
    end):start()

    -- Re-check after focus changes, including changing displays within one app.
    runtime.focusFilter = hs.window.filter.new()
    runtime.focusFilter:subscribe({
        [hs.window.filter.windowFocused] = function()
            if runtime.placement.mode == MODE_FOCUS then
                scheduleReconcile("focused_window_changed")
            end
        end,
    })
    runtime.applicationWatcher = hs.application.watcher.new(function(_, event)
        if event == hs.application.watcher.activated and runtime.placement.mode == MODE_FOCUS then
            scheduleReconcile("frontmost_application_changed")
        end
    end):start()

    reconcileWindows("startup_scan")
    local placement = placementSnapshot()
    placement.type = "auto_assignment_enabled"
    append(placement)
end

local function updateMenuLabel()
    if not runtime.menu then return end
    if hs.settings.get("codexComputerUseSafetySuspended")==true then
        runtime.menu:setTitle("CU 暂停排查")
        runtime.menu:setTooltip("安全暂停中，自动分配保持停止")
        return
    end
    runtime.menu:setTitle(runtime.enabled and "CU副屏 ●" or "CU副屏 ○")
    if runtime.placement.mode == MODE_FIXED then
        runtime.menu:setTooltip("Codex 小预览固定到："
            .. (runtime.placement.fixedScreenName or "尚未指定的屏幕"))
    else
        runtime.menu:setTooltip("Codex 小预览放到当前焦点窗口所在屏幕的另一块屏")
    end
end

local function setEnabled(enabled)
    runtime.enabled = enabled == true
    hs.settings.set(SETTINGS_KEY, runtime.enabled)
    if assignmentAllowed() then
        startWatcher()
    else
        stopWatcher()
        local placement = placementSnapshot()
        placement.type = "auto_assignment_disabled"
        append(placement)
    end
    updateMenuLabel()
end

local function setPlacement(mode, uuid, name)
    local previous = runtime.placement
    local nextPlacement = {
        mode = mode,
        fixedScreenUUID = uuid or previous.fixedScreenUUID,
        fixedScreenName = name or previous.fixedScreenName,
    }
    if previous.mode == nextPlacement.mode
        and previous.fixedScreenUUID == nextPlacement.fixedScreenUUID
        and previous.fixedScreenName == nextPlacement.fixedScreenName then return end

    hs.settings.set(PLACEMENT_SETTINGS_KEY, nextPlacement)
    runtime.placement = nextPlacement
    runtime.targetUnavailableLogged = {}
    runtime.moveBudget = {}
    updateMenuLabel()
    local placement = placementSnapshot()
    placement.type = "placement_configuration_changed"
    append(placement)
    scheduleReconcile("placement_configuration_changed")
end

local function fixedScreenMenu()
    local screens = hs.screen.allScreens()
    table.sort(screens, function(a, b)
        local aName, bName = a:name() or "", b:name() or ""
        if aName == bName then return a:id() < b:id() end
        return aName < bName
    end)
    local nameCounts = {}
    for _, screen in ipairs(screens) do
        local name = screen:name() or "未命名屏幕"
        nameCounts[name] = (nameCounts[name] or 0) + 1
    end

    local menu, selectedConnected = {}, false
    for _, screen in ipairs(screens) do
        -- Capture values, so choosing a menu item stores the screen's UUID,
        -- never its list position or its changing numeric display ID.
        local uuid, name = screen:getUUID(), screen:name() or "未命名屏幕"
        local selectable = type(uuid) == "string" and uuid ~= ""
        local selected = runtime.placement.mode == MODE_FIXED
            and selectable and uuid == runtime.placement.fixedScreenUUID
        selectedConnected = selectedConnected or selected
        menu[#menu + 1] = {
            title = nameCounts[name] > 1
                and (name .. "（编号 " .. tostring(screen:id()) .. "）") or name,
            checked = selected,
            disabled = not selectable,
            fn = selectable and function() setPlacement(MODE_FIXED, uuid, name) end or nil,
        }
    end
    if runtime.placement.mode == MODE_FIXED and not selectedConnected then
        table.insert(menu, 1, {
            title = (runtime.placement.fixedScreenName or "指定屏幕") .. "（未连接，暂停移动）",
            checked = true,
            disabled = true,
        })
    end
    if #menu == 0 then menu[1] = { title = "没有可选屏幕", disabled = true } end
    return menu
end

local UNAVAILABLE_LABELS = {
    requires_exactly_two_screens = "跟随焦点需要连接两块屏幕",
    focused_window_unavailable = "暂时找不到当前焦点窗口",
    focused_screen_unavailable = "暂时找不到焦点窗口所在屏幕",
    focused_screen_not_connected = "焦点窗口所在屏幕未连接",
    opposite_screen_unavailable = "暂时找不到另一块屏幕",
    fixed_screen_not_configured = "尚未指定副屏",
    fixed_screen_not_connected = "指定副屏未连接，暂停移动",
}

runtime.enabled = hs.settings.get(SETTINGS_KEY)
if runtime.enabled == nil then runtime.enabled = true end

runtime.menu = runtime.menu or hs.menubar.new()
-- The same menu builder is available to diagnostics, so acceptance checks can
-- inspect choices and exercise their handlers without opening a GUI menu.
runtime.menuItems = function()
    local suspended=hs.settings.get("codexComputerUseSafetySuspended")==true
    local placement = placementSnapshot()
    local status = placement.targetScreenName and ("目标副屏：" .. placement.targetScreenName)
        or UNAVAILABLE_LABELS[placement.reason] or "暂时无法确定副屏"
    return {
        {
            title = suspended and "安全暂停，自动分配保持停止" or (runtime.enabled and "暂停自动分配" or "开启自动分配"),
            disabled = suspended,
            fn = not suspended and function() setEnabled(not runtime.enabled) end or nil,
        },
        { title = "-" },
        {
            title = "跟随焦点，使用另一块屏",
            checked = runtime.placement.mode == MODE_FOCUS,
            fn = function() setPlacement(MODE_FOCUS) end,
        },
        {
            title = "固定使用指定副屏",
            checked = runtime.placement.mode == MODE_FIXED,
            menu = fixedScreenMenu(),
        },
        { title = status, disabled = true },
        { title = "-" },
        {
            title = "记录当前选屏设置和匹配窗口",
            fn = function()
                local windows = {}
                for _, window in ipairs(hs.window.allWindows()) do
                    if eligible(window) then
                        windows[#windows + 1] = {
                            id = window:id(),
                            title = window:title(),
                            screenUUID = screenUUID(window),
                            frame = frameInfo(window),
                        }
                    end
                end
                local snapshot = placementSnapshot()
                snapshot.type = "manual_snapshot"
                snapshot.windows = windows
                append(snapshot)
            end,
        },
    }
end
if runtime.menu then
    updateMenuLabel()
    runtime.menu:setMenu(runtime.menuItems)
end

-- Detach callbacks from a previous reload before installing this version.
stopWatcher()
if assignmentAllowed() then startWatcher() else stopWatcher() end
