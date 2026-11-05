-- Temporary, read-only audit. Never records AXValue, text, or window titles.
-- Load with dofile(); call start() before a test and finish() afterwards.
local audit = { records = {}, observers = {} }

local function attribute(element, name)
    if not element then return nil end
    local ok, value = pcall(function() return element:attributeValue(name) end)
    return ok and value or nil
end

function audit.snapshot()
    local app = hs.application.frontmostApplication()
    local window = app and app:focusedWindow()
    local element = app and attribute(hs.axuielement.applicationElement(app), "AXFocusedUIElement")
    local elementWindow = attribute(element, "AXWindow")
    local elementHSWindow = elementWindow and elementWindow:asHSWindow()
    local mouse = hs.mouse.absolutePosition()
    local state = {
        observerActive = audit.running == true,
        epochSeconds = hs.timer.secondsSinceEpoch(),
        bundleID = app and app:bundleID(),
        windowId = window and window:id(),
        elementRole = attribute(element, "AXRole"),
        elementWindowId = elementHSWindow and elementHSWindow:id(),
        sameElementAsStart = audit.initialElement ~= nil and element == audit.initialElement,
        mousePosition = { x = mouse.x, y = mouse.y },
        chromeWindows = {},
    }
    for _, item in ipairs(hs.window.allWindows()) do
        local owner = item:application()
        if owner and owner:bundleID() == "com.google.Chrome" then
            local frame = item:frame()
            state.chromeWindows[#state.chromeWindows + 1] = {
                id = item:id(), pid = owner:pid(), screenUUID = item:screen():getUUID(),
                frame = { x = frame.x, y = frame.y, w = frame.w, h = frame.h },
            }
        end
    end
    return state
end

function audit.record(event)
    local state = audit.snapshot()
    state.event = event
    audit.records[#audit.records + 1] = state
    return state
end

function audit.finish()
    if not audit.running then return audit.records end
    audit.running = false
    for _, observer in ipairs(audit.observers) do observer:stop() end
    if audit.appWatcher then audit.appWatcher:stop() end
    if audit.timer then audit.timer:stop() end
    audit.record("finished")
    return audit.records
end

function audit.start()
    assert(not audit.running, "audit already running")
    audit.running = true
    local front = hs.application.frontmostApplication()
    audit.initialElement = front and attribute(hs.axuielement.applicationElement(front), "AXFocusedUIElement")
    audit.record("started")
    for _, bundle in ipairs({ "com.openai.codex", "com.google.Chrome" }) do
        local app = hs.application.get(bundle)
        if app then
            local observer = hs.axuielement.observer.new(app:pid())
            observer:callback(function(_, _, event) audit.record(bundle .. ":" .. event) end)
            for _, event in ipairs({ "AXFocusedWindowChanged", "AXFocusedUIElementChanged", "AXWindowCreated" }) do
                observer:addWatcher(hs.axuielement.applicationElement(app), event)
            end
            observer:start()
            audit.observers[#audit.observers + 1] = observer
        end
    end
    audit.appWatcher = hs.application.watcher.new(function(name, event, app)
        if event == hs.application.watcher.activated then
            audit.record("activated:" .. (app and app:bundleID() or name or "unknown"))
        end
    end):start()
    audit.timer = hs.timer.doAfter(180, function() audit.finish() end)
    return audit
end

return audit
