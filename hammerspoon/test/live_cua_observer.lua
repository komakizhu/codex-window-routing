-- Temporary, read-only observer for one native Computer Use acceptance run.
-- Window titles are logged only for the disposable probe app and obvious PiP
-- windows; Codex chat titles and other personal window titles are redacted.

local ALLOWED_WINDOW_APPS = {
    ["com.openai.codex"] = true,
    ["com.openai.sky.CUAService"] = true,
    ["com.openai.sky.CUAService.cli"] = true,
    ["org.codex.isolation.WindowProbe"] = true,
}
local PROBE_BUNDLE_ID = "org.codex.isolation.WindowProbe"
local LOG_PATH = hs.configdir .. "/computer-use-live-test.jsonl"

hs._codexCULiveObserver = hs._codexCULiveObserver or {}
local runtime = hs._codexCULiveObserver

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

local function currentFrontmost()
    local app = hs.application.frontmostApplication()
    if not app then return nil end
    return { bundleID = safeCall(function() return app:bundleID() end) }
end

local function mousePosition()
    local p = hs.mouse.absolutePosition()
    return p and { x = p.x, y = p.y } or nil
end

local function append(record)
    record.timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
    record.epochSeconds = hs.timer.secondsSinceEpoch()
    record.frontmostApp = currentFrontmost()
    record.mousePosition = mousePosition()

    local ok, encoded = pcall(hs.json.encode, record)
    if not ok or type(encoded) ~= "string" then
        hs.printf("live-cua-observer: JSON encode failed: %s", tostring(encoded))
        return
    end

    local file, err = io.open(LOG_PATH, "a")
    if not file then
        hs.printf("live-cua-observer: cannot append log: %s", tostring(err))
        return
    end
    file:write(encoded, "\n")
    file:flush()
    file:close()
end

local function screenInfo(screen)
    if not screen then return nil end
    local frame = safeCall(function() return screen:fullFrame() end)
    return {
        name = safeCall(function() return screen:name() end),
        uuid = safeCall(function() return screen:getUUID() end),
        frame = frame and { x = frame.x, y = frame.y, w = frame.w, h = frame.h } or nil,
    }
end

local function isPipTitle(title)
    return type(title) == "string"
        and title:lower():find("pip", 1, true) ~= nil
        or type(title) == "string" and title:lower():find("picture in picture", 1, true) ~= nil
        or type(title) == "string" and title:lower():find("computer use", 1, true) ~= nil
        or type(title) == "string" and title:lower():find("software cursor", 1, true) ~= nil
end

local function windowInfo(window)
    if not window then return nil end
    local app = safeCall(function() return window:application() end)
    local appData = appInfo(app)
    local bundleID = appData and appData.bundleID
    if not bundleID or not ALLOWED_WINDOW_APPS[bundleID] then return nil end

    local title = safeCall(function() return window:title() end) or ""
    local frame = safeCall(function() return window:frame() end)
    local screen = safeCall(function() return window:screen() end)
    local keepTitle = bundleID == PROBE_BUNDLE_ID or isPipTitle(title)

    local ax = safeCall(function() return hs.axuielement.windowElement(window) end)
    local attributes = {}
    if ax then
        for _, key in ipairs({ "AXRole", "AXSubrole", "AXIdentifier", "AXWindowNumber" }) do
            local value = safeCall(function() return ax:attributeValue(key) end)
            local kind = type(value)
            if kind == "string" or kind == "number" or kind == "boolean" then
                attributes[key] = value
            end
        end
        if keepTitle then
            local value = safeCall(function() return ax:attributeValue("AXTitle") end)
            if type(value) == "string" then attributes.AXTitle = value end
        end
    end

    return {
        id = safeCall(function() return window:id() end),
        title = keepTitle and title or "",
        titleRedacted = not keepTitle and title ~= "",
        role = safeCall(function() return window:role() end),
        subrole = safeCall(function() return window:subrole() end),
        isStandard = safeCall(function() return window:isStandard() end),
        isVisible = safeCall(function() return window:isVisible() end),
        frame = frame and { x = frame.x, y = frame.y, w = frame.w, h = frame.h } or nil,
        screen = screenInfo(screen),
        app = appData,
        accessibility = attributes,
    }
end

local function logScreens(reason)
    local screens = {}
    for _, screen in ipairs(hs.screen.allScreens()) do
        screens[#screens + 1] = screenInfo(screen)
    end
    append({ type = "screen_inventory", reason = reason, screens = screens })
end

local function onWindowEvent(window, appName, event)
    local info = windowInfo(window)
    if not info then return end
    append({ type = "window_event", event = event, appName = appName, window = info })
end

local filter = hs.window.filter.new(false):setDefaultFilter({ allowRoles = "*" })
local subscriptions = {}
for _, event in ipairs({
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
}) do
    subscriptions[event] = onWindowEvent
end
filter:subscribe(subscriptions)
runtime.filter = filter

local appWatcher = hs.application.watcher.new(function(name, event, app)
    local info = appInfo(app)
    local bundleID = info and info.bundleID
    local relevant = bundleID and ALLOWED_WINDOW_APPS[bundleID]
    local focusEvent = event == hs.application.watcher.activated
        or event == hs.application.watcher.deactivated
    if relevant or focusEvent then
        append({
            type = "application_event",
            eventCode = event,
            app = relevant and info or { bundleID = bundleID },
        })
    end
end):start()
runtime.appWatcher = appWatcher

local screenWatcher = hs.screen.watcher.new(function()
    logScreens("display_change")
end):start()
runtime.screenWatcher = screenWatcher

append({ type = "observer_started", logPath = LOG_PATH })
logScreens("observer_started")
for _, window in ipairs(filter:getWindows()) do
    local info = windowInfo(window)
    if info then append({ type = "window_snapshot", reason = "observer_started", window = info }) end
end
