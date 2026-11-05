-- Read-only observer for investigating Codex Computer Use window ownership.
-- This module never moves, resizes, raises, hides, or focuses windows.

local M = {}

local LOG_PATH = hs.configdir .. "/computer-use-observer.jsonl"
local running = false
local windowFilter = nil
local appWatcher = nil
local screenWatcher = nil
local menuBar = nil
local lastEventByWindow = {}
local firstSeenByWindow = {}
local baselineWindowIds = {}

local function utcTimestamp()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function primitive(value)
    local kind = type(value)
    if kind == "string" or kind == "number" or kind == "boolean" then
        return value
    end
    return nil
end

local function safeCall(fn)
    local ok, value = pcall(fn)
    if ok then return value end
    return nil
end

local function appInfo(app)
    if not app then return nil end
    return {
        name = safeCall(function() return app:name() end),
        bundleID = safeCall(function() return app:bundleID() end),
        pid = safeCall(function() return app:pid() end),
    }
end

local function frontmostInfo()
    return appInfo(hs.application.frontmostApplication())
end

local function screenInfo(screen)
    if not screen then return nil end
    local full = safeCall(function() return screen:fullFrame() end)
    local visible = safeCall(function() return screen:frame() end)
    local position = safeCall(function()
        local x, y = screen:position()
        return { x = x, y = y }
    end)
    local primary = hs.screen.primaryScreen()
    local main = hs.screen.mainScreen()
    local uuid = safeCall(function() return screen:getUUID() end)
    return {
        name = safeCall(function() return screen:name() end),
        id = safeCall(function() return screen:id() end),
        uuid = uuid,
        position = position,
        fullFrame = full and { x = full.x, y = full.y, w = full.w, h = full.h } or nil,
        visibleFrame = visible and { x = visible.x, y = visible.y, w = visible.w, h = visible.h } or nil,
        isPrimary = primary and uuid == safeCall(function() return primary:getUUID() end) or false,
        isMain = main and uuid == safeCall(function() return main:getUUID() end) or false,
    }
end

local function screenInventory()
    local out = {}
    for _, screen in ipairs(hs.screen.allScreens()) do
        out[#out + 1] = screenInfo(screen)
    end
    return out
end

local function accessibilityInfo(window)
    local element = safeCall(function() return hs.axuielement.windowElement(window) end)
    if not element then
        return { available = false }
    end

    local ok, names, namesError = pcall(function() return element:attributeNames() end)
    if not ok then
        return { available = false, error = tostring(names) }
    end
    local values = {}
    local selected = {
        AXRole = true,
        AXSubrole = true,
        AXTitle = true,
        AXDescription = true,
        AXIdentifier = true,
        AXHelp = true,
        AXWindowNumber = true,
    }

    if type(names) == "table" then
        for _, name in ipairs(names) do
            if selected[name] then
                local value, err
                local valueOk, returnedValue, returnedError = pcall(function()
                    return element:attributeValue(name)
                end)
                if valueOk then
                    value, err = returnedValue, returnedError
                else
                    err = returnedValue
                end
                values[name] = primitive(value)
                if err then values[name .. "Error"] = tostring(err) end
            end
        end
    end

    return {
        available = type(names) == "table",
        attributeNames = type(names) == "table" and names or nil,
        attributes = values,
        error = namesError and tostring(namesError) or nil,
    }
end

local function windowInfo(window)
    if not window then return nil end
    local app = safeCall(function() return window:application() end)
    local frame = safeCall(function() return window:frame() end)
    local screen = safeCall(function() return window:screen() end)
    local id = safeCall(function() return window:id() end)
    local sid = id and tostring(id) or "unknown"

    return {
        id = id,
        title = safeCall(function() return window:title() end),
        role = safeCall(function() return window:role() end),
        subrole = safeCall(function() return window:subrole() end),
        isStandard = safeCall(function() return window:isStandard() end),
        isVisible = safeCall(function() return window:isVisible() end),
        isFullScreen = safeCall(function() return window:isFullScreen() end),
        frame = frame and { x = frame.x, y = frame.y, w = frame.w, h = frame.h } or nil,
        screen = screenInfo(screen),
        app = appInfo(app),
        accessibility = accessibilityInfo(window),
        firstObservedAt = firstSeenByWindow[sid],
    }
end

local function append(record)
    record.timestamp = utcTimestamp()
    record.epochSeconds = hs.timer.secondsSinceEpoch()
    record.foregroundApp = frontmostInfo()
    local ok, encoded = pcall(hs.json.encode, record)
    if not ok then
        hs.printf("computer-use-observer: JSON encode failed: %s", tostring(encoded))
        return
    end
    local file, err = io.open(LOG_PATH, "a")
    if not file then
        hs.printf("computer-use-observer: cannot append log: %s", tostring(err))
        return
    end
    file:write(encoded, "\n")
    file:flush()
    file:close()
end

local function dedupeKey(event, info)
    return tostring(event) .. ":" .. tostring(info and info.id or "unknown")
end

local function onWindowEvent(window, appName, event)
    local info = windowInfo(window)
    if not info then return end

    local key = tostring(info.id or "unknown")
    local loggedEvent = event
    if event == hs.window.filter.windowCreated and baselineWindowIds[key] then
        loggedEvent = "windowPresentAtObserverStart"
        baselineWindowIds[key] = nil
    elseif event == hs.window.filter.windowCreated then
        firstSeenByWindow[key] = utcTimestamp()
        info.firstObservedAt = firstSeenByWindow[key]
        info.createdAtObserved = firstSeenByWindow[key]
    elseif not firstSeenByWindow[key] then
        firstSeenByWindow[key] = utcTimestamp()
        info.firstObservedAt = firstSeenByWindow[key]
    end

    local now = hs.timer.secondsSinceEpoch()
    local signature = hs.json.encode({
        title = info.title or "",
        frame = info.frame,
        screenUUID = info.screen and info.screen.uuid or "",
    })
    local dedupe = dedupeKey(event, info)
    local previous = lastEventByWindow[dedupe]
    if previous and previous.signature == signature and now - previous.at < 0.2 then
        return
    end
    lastEventByWindow[dedupe] = { at = now, signature = signature }

    append({
        type = "window_event",
        event = loggedEvent,
        sourceEvent = event,
        appName = appName,
        window = info,
    })

    if event == hs.window.filter.windowDestroyed then
        firstSeenByWindow[key] = nil
        baselineWindowIds[key] = nil
        local suffix = ":" .. key
        for cachedKey in pairs(lastEventByWindow) do
            if cachedKey:sub(-#suffix) == suffix then lastEventByWindow[cachedKey] = nil end
        end
    end
end

local function logScreens(reason)
    append({
        type = "screen_inventory",
        reason = reason,
        screens = screenInventory(),
    })
end

local function snapshotWindows(reason)
    local windows = windowFilter and windowFilter:getWindows() or hs.window.allWindows()
    for _, window in ipairs(windows) do
        local info = windowInfo(window)
        if info then
            local key = tostring(info.id or "unknown")
            if not firstSeenByWindow[key] then
                firstSeenByWindow[key] = utcTimestamp()
                info.firstObservedAt = firstSeenByWindow[key]
            end
            append({ type = "window_snapshot", reason = reason, window = info })
        end
    end
end

local function stop()
    if not running then return end
    running = false
    if windowFilter then
        windowFilter:unsubscribeAll()
        windowFilter = nil
    end
    if appWatcher then
        appWatcher:stop()
        appWatcher = nil
    end
    if screenWatcher then
        screenWatcher:stop()
        screenWatcher = nil
    end
    baselineWindowIds = {}
    firstSeenByWindow = {}
    lastEventByWindow = {}
    append({ type = "observer_stopped" })
    if menuBar then menuBar:setTitle("CU观察 ○") end
end

local function start()
    if running then return end
    local ok, authorized = pcall(hs.accessibilityState, false)
    if not ok or not authorized then
        append({
            type = "observer_start_blocked",
            reason = "accessibility_permission_missing",
        })
        if menuBar then menuBar:setTitle("CU观察 🔒") end
        return false
    end
    running = true

    local wf = hs.window.filter.new(false):setDefaultFilter({ allowRoles = "*" })
    windowFilter = wf
    baselineWindowIds = {}
    for _, window in ipairs(wf:getWindows()) do
        local id = safeCall(function() return window:id() end)
        if id then baselineWindowIds[tostring(id)] = true end
    end

    local appEventNames = {
        [hs.application.watcher.launching] = "launching",
        [hs.application.watcher.launched] = "launched",
        [hs.application.watcher.terminated] = "terminated",
        [hs.application.watcher.hidden] = "hidden",
        [hs.application.watcher.unhidden] = "unhidden",
        [hs.application.watcher.activated] = "activated",
        [hs.application.watcher.deactivated] = "deactivated",
    }
    local subscriptions = {}
    local events = {
        hs.window.filter.windowCreated,
        hs.window.filter.windowDestroyed,
        hs.window.filter.windowMoved,
        hs.window.filter.windowFocused,
        hs.window.filter.windowUnfocused,
        hs.window.filter.windowTitleChanged,
        hs.window.filter.windowOnScreen,
        hs.window.filter.windowNotOnScreen,
        hs.window.filter.windowMinimized,
        hs.window.filter.windowUnminimized,
        hs.window.filter.windowFullscreened,
        hs.window.filter.windowUnfullscreened,
    }
    for _, event in ipairs(events) do
        subscriptions[event] = onWindowEvent
    end
    wf:subscribe(subscriptions)

    appWatcher = hs.application.watcher.new(function(name, event, app)
        append({
            type = "application_event",
            event = appEventNames[event] or tostring(event),
            eventCode = event,
            appName = name,
            app = appInfo(app),
        })
    end):start()

    screenWatcher = hs.screen.watcher.new(function()
        logScreens("display_change")
    end):start()

    append({ type = "observer_started", logPath = LOG_PATH })
    logScreens("observer_started")
    snapshotWindows("observer_started")
    append({ type = "foreground_snapshot" })
    if menuBar then menuBar:setTitle("CU观察 ●") end
end

function M.start()
    return start()
end

function M.stop()
    stop()
end

function M.isRunning()
    return running
end

function M.logPath()
    return LOG_PATH
end

menuBar = hs.menubar.new()
local function refreshMenuTitle()
    if not menuBar then return end
    if running then
        menuBar:setTitle("CU观察 ●")
        return
    end
    local ok, authorized = pcall(hs.accessibilityState, false)
    menuBar:setTitle(ok and authorized and "CU观察 ○" or "CU观察 🔒")
end

if menuBar then
    refreshMenuTitle()
    menuBar:setTooltip("Codex Computer Use：只记录窗口事件，不移动或聚焦窗口")
    menuBar:setMenu(function()
        refreshMenuTitle()
        return {
            {
                title = running and "暂停窗口观察" or "开始窗口观察",
                fn = function()
                    if running then stop() else start() end
                end,
            },
            {
                title = "记录当前窗口与显示器",
                fn = function()
                    local ok, authorized = pcall(hs.accessibilityState, false)
                    if running and ok and authorized then
                        logScreens("manual_snapshot")
                        snapshotWindows("manual_snapshot")
                        append({ type = "foreground_snapshot" })
                    else
                        append({
                            type = "snapshot_blocked",
                            reason = authorized and "observer_not_running" or "accessibility_permission_missing",
                        })
                        refreshMenuTitle()
                    end
                end,
            },
        }
    end)
end

return M
