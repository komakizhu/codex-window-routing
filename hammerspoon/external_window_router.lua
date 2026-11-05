-- Explicit opening intent and exact window IDs, never "all windows of Codex's
-- target app". Physical Dock/reveal actions are handled separately.
if hs._codexExternalWindowRouter and hs._codexExternalWindowRouter.stop then
    hs._codexExternalWindowRouter.stop()
end
local r = hs._codexExternalWindowRouter or { owners = {}, sequence = 0 }
hs._codexExternalWindowRouter = r
r.tickets = r.tickets or {} -- keep another chat's in-flight opening on reload
for token, ticket in pairs(r.tickets) do
    if ticket.expires < hs.timer.secondsSinceEpoch() then r.tickets[token] = nil end
end
r.pendingHuman = nil
local CHROME, FINDER = "com.google.Chrome", "com.apple.finder"
local LOG = hs.configdir .. "/external-window-routing.jsonl"

local function log(record)
    record.epochSeconds = hs.timer.secondsSinceEpoch()
    local file = io.open(LOG, "a")
    if file then file:write(hs.json.encode(record), "\n"); file:close() end
end
local function normal(w)
    return w and w:role() == "AXWindow" and w:subrole() == "AXStandardWindow"
end
local function enabled()
    return hs._codexComputerUseSidecar and hs._codexComputerUseSidecar.enabled
end
local function windows(bundle)
    local result = {}
    -- One bundle can have several application processes (for example a private
    -- Obsidian test profile). get(bundle) selects just one and loses exact IDs
    -- returned for the other process. Enumerate all, then still claim only the
    -- explicitly identified new window.
    for _, app in ipairs(hs.application.applicationsForBundleID(bundle) or {}) do
        for _, w in ipairs(app:allWindows()) do
            if normal(w) then result[w:id()] = w end
        end
    end
    return result
end
local function screen(uuid)
    for _, value in ipairs(hs.screen.allScreens()) do
        if value:getUUID() == uuid then return value end
    end
end
local function owned(w, intent)
    local owner = w and r.owners[w:id()]
    local app = w and w:application()
    return owner and app and owner.pid == app:pid() and owner.intent == intent
end
local function move(w, plan, intent, event)
    local target = screen(plan.targetScreenUUID)
    if not enabled() or not target or not normal(w) then
        log({ type = "move_failed", intent = intent, event = event,
            reason = not enabled() and "auto_assignment_paused" or "target_or_window_unavailable" })
        return nil, "target_or_window_unavailable"
    end
    local app = w:application()
    local before = w:screen() and w:screen():getUUID()
    if before ~= target:getUUID() then
        local ok, err = pcall(function() w:moveToScreen(target, true, true, 0) end)
        if not ok then
            log({ type = "move_failed", intent = intent, event = event,
                windowId = w:id(), error = tostring(err) })
            return nil, "window_move_failed"
        end
    end
    r.owners[w:id()] = { pid = app:pid(), bundleID = app:bundleID(), intent = intent }
    local after = w:screen() and w:screen():getUUID()
    log({ type = "route", intent = intent, event = event, windowId = w:id(), pid = app:pid(),
        bundleID = app:bundleID(), beforeScreenUUID = before, targetScreenUUID = target:getUUID(),
        afterScreenUUID = after, verified = after == target:getUUID() })
    return after == target:getUUID(), w:id()
end

function r.begin(intent, bundle, allowExistingReview)
    assert(type(bundle) == "string" and bundle ~= "", "bundle ID required")
    local plan = hs._codexComputerUseSidecar.placementForIntent(intent)
    if plan.reason or not plan.bounds then return nil, plan.reason end
    r.sequence = r.sequence + 1
    local token = tostring(r.sequence)
    local baseline = {}
    for id in pairs(windows(bundle)) do baseline[id] = true end
    r.tickets[token] = { intent = intent, bundle = bundle, plan = plan, baseline = baseline,
        physicalSequence = r.physicalSequence,
        allowExisting = intent ~= "automation" and allowExistingReview == true,
        expires = hs.timer.secondsSinceEpoch() + 120 }
    log({ type = "begin", token = token, intent = intent, bundleID = bundle,
        targetScreenUUID = plan.targetScreenUUID })
    return token, plan
end

function r.finish(token, explicitWindowId)
    local ticket = r.tickets[tostring(token)]
    r.tickets[tostring(token)] = nil
    local function reject(reason)
        log({ type = "route_rejected", token = tostring(token),
            intent = ticket and ticket.intent, reason = reason })
        return nil, reason
    end
    if not ticket or ticket.expires < hs.timer.secondsSinceEpoch() then return reject("opening_ticket_expired") end
    if not enabled() then return reject("auto_assignment_paused") end
    if not explicitWindowId and ticket.physicalSequence ~= r.physicalSequence then
        return reject("user_input_during_open_requires_exact_window_id")
    end
    local current = windows(ticket.bundle)
    local w = explicitWindowId and current[explicitWindowId] or nil
    if explicitWindowId and (not w or (ticket.baseline[explicitWindowId] and not ticket.allowExisting)) then
        return reject("existing_or_unrelated_window_not_claimed")
    end
    if not explicitWindowId then
        local count = 0
        for id, value in pairs(current) do
            if not ticket.baseline[id] then count = count + 1; w = value end
        end
        if count ~= 1 then return reject("new_window_not_unique") end
    end
    local ok, id = move(w, ticket.plan, ticket.intent, "explicit_open")
    if ok and ticket.bundle == CHROME and ticket.intent ~= "automation" then r.personalChromeId = id end
    if ok and ticket.bundle == CHROME then r.restorePersonalChromeMain() end
    return ok, id
end

-- Finder's normal `open` can reuse a personal window. Create one with its
-- initial bounds instead, and use only the returned exact window identifier.
-- macOS may require the user to grant Hammerspoon permission to automate Finder.
function r.openFinderWindow(intent, directory)
    assert(type(directory) == "string" and directory:sub(1, 1) == "/"
        and not directory:find("[%z\r\n]"), "absolute directory path required")
    assert(hs.fs.attributes(directory, "mode") == "directory", "directory does not exist")
    local token, plan = r.begin(intent, FINDER)
    if not token then return nil, { reason = plan } end
    local escaped = directory:gsub("\\", "\\\\"):gsub('"', '\\"')
    local b = plan.bounds
    local script = string.format([[
with timeout of 2 seconds
    tell application id "com.apple.finder"
        set createdWindow to make new Finder window with properties {target:(POSIX file "%s" as alias), bounds:{%d,%d,%d,%d}}
        return id of createdWindow
    end tell
end timeout]], escaped, b.left, b.top, b.left + b.width, b.top + b.height)
    local front = hs.application.frontmostApplication()
    local beforePID = front and front:pid()
    local success, value, err = hs.osascript.applescript(script)
    local id = success and tonumber(value)
    if not success or not id then
        r.tickets[token] = nil
        local result = { reason = "finder_create_failed", error = err }
        log({ type = "finder_create_failed", intent = intent, error = err })
        return nil, result
    end
    local ok, detail = r.finish(token, id)
    front = hs.application.frontmostApplication()
    local changed = beforePID ~= (front and front:pid())
    local result = { windowId = id, targetScreenUUID = plan.targetScreenUUID,
        foregroundChanged = changed,
        reason = not ok and "finder_route_failed" or changed and "foreground_changed_during_finder_create" or nil,
        detail = not ok and detail or nil }
    log({ type = "finder_create_result", intent = intent, windowId = id,
        routed = ok == true, foregroundChanged = changed })
    return ok == true and not changed or nil, result
end

-- Migration only for a window whose ownership has been independently verified
-- by the browser's returned window/tab/group IDs. Never called by a scan.
function r.adoptVerifiedAutomationWindow(id)
    local w = hs.window.get(id)
    assert(normal(w), "normal window required")
    local app = w:application()
    r.owners[id] = { pid = app:pid(), bundleID = app:bundleID(), intent = "automation" }
end

function r.restorePersonalChromeMain()
    if not enabled() then return false end
    local w = r.personalChromeId and hs.window.get(r.personalChromeId)
    local front = hs.application.frontmostApplication()
    if w and owned(w, "review") and front and front:bundleID() ~= CHROME then
        w:becomeMain() -- documented to leave the foreground application alone
        return true
    end
    return false
end

local function attribute(element, name)
    if not element then return nil end
    local ok, value = pcall(function() return element:attributeValue(name) end)
    return ok and value or nil
end
local function hardware(e)
    local p = hs.eventtap.event.properties
    return e:getProperty(p.eventSourceUnixProcessID) == 0
        and e:getProperty(p.eventSourceStateID) == 1
end
local REVEAL = { ["Reveal in Finder"] = true, ["Show in Finder"] = true,
    ["Open in Finder"] = true, ["在 Finder 中显示"] = true,
    ["在访达中显示"] = true, ["在访达中打开"] = true }
local function humanRequest(bundle, kind, capturedPlan)
    if not enabled() then return end
    local plan = capturedPlan or hs._codexComputerUseSidecar.placementForIntent("review")
    if plan.reason == "auto_assignment_paused" then
        -- A cached screen can predate the user resuming from the menu. Rebuild
        -- bounds for THAT screen, not the app activated by the subsequent click.
        local target = screen(plan.targetScreenUUID)
        if target then
            local frame = target:frame()
            plan = { intent = "review", enabled = true, targetScreenUUID = target:getUUID(),
                bounds = { left = math.floor(frame.x + 40), top = math.floor(frame.y + 40),
                    width = math.floor(math.min(1100, frame.w - 80)),
                    height = math.floor(math.min(800, frame.h - 80)), focused = false, state = "normal" } }
        end
    end
    if plan.reason then return end
    local baseline = {}
    for id in pairs(windows(bundle)) do baseline[id] = true end
    r.pendingHuman = { bundle = bundle, kind = kind, plan = plan, baseline = baseline,
        expires = hs.timer.secondsSinceEpoch() + 4, creating = false }
    log({ type = "human_request", bundleID = bundle, kind = kind,
        targetScreenUUID = plan.targetScreenUUID })
end
local function handleHumanChrome()
    if not enabled() then return end
    local request = r.pendingHuman
    local front = hs.application.frontmostApplication()
    if not request or request.bundle ~= CHROME or request.expires < hs.timer.secondsSinceEpoch()
        or not front or front:bundleID() ~= CHROME then return end
    local current = windows(CHROME)
    local fresh, count = nil, 0
    for id, w in pairs(current) do
        if not request.baseline[id] then fresh = w; count = count + 1 end
    end
    if count == 1 then
        move(fresh, request.plan, "review", "physical_chrome_open")
        r.personalChromeId = fresh:id()
        r.pendingHuman = nil
        return
    elseif count > 1 then r.pendingHuman = nil; return end
    if request.kind == "new_window" then return end
    local personal = r.personalChromeId and current[r.personalChromeId]
    if personal and owned(personal, "review") and personal:screen():getUUID() == request.plan.targetScreenUUID then
        -- The user just requested Chrome through its Dock icon. One response to
        -- that physical action; no timer repeatedly reclaims focus.
        personal:focus()
        r.pendingHuman = nil
    elseif not request.creating then
        local active = front:focusedWindow()
        if active and not owned(active, "automation")
            and active:screen():getUUID() == request.plan.targetScreenUUID then
            r.personalChromeId = active:id()
            r.owners[active:id()] = { pid = front:pid(), bundleID = CHROME, intent = "review" }
            r.pendingHuman = nil
            return
        end
        request.creating = true
        local selected = front:selectMenuItem({ "文件", "新建窗口" })
            or front:selectMenuItem({ "File", "New Window" })
        if not selected then r.pendingHuman = nil; log({ type = "human_open_failed", reason = "new_window_menu_unavailable" }) end
    end
end

function r.stop()
    if r.tap then r.tap:stop() end
    if r.appWatcher then r.appWatcher:stop() end
    if r.chromeFilter then r.chromeFilter:unsubscribeAll() end
    if r.finderFilter then r.finderFilter:unsubscribeAll() end
    if r.focusFilter then r.focusFilter:unsubscribeAll() end
    if r.mainTimer then r.mainTimer:stop() end
end

r.cachedReviewPlan = hs._codexComputerUseSidecar.placementForIntent("review")
r.physicalSequence = r.physicalSequence or 0
r.tap = hs.eventtap.new({ hs.eventtap.event.types.leftMouseDown, hs.eventtap.event.types.keyDown }, function(e)
    if not enabled() or not hardware(e) then return false end
    r.physicalSequence = r.physicalSequence + 1
    local sequence, plan = r.physicalSequence, r.cachedReviewPlan
    r.pendingHuman = nil
    if e:getType() == hs.eventtap.event.types.keyDown then
        local front = hs.application.frontmostApplication()
        if front and front:bundleID() == CHROME and e:getFlags().cmd and e:getKeyCode() == hs.keycodes.map.n then
            hs.timer.doAfter(0, function()
                if r.physicalSequence == sequence then humanRequest(CHROME, "new_window", plan) end
            end)
        end
        return false
    end
    local point = e:location()
    local front = hs.application.frontmostApplication()
    local frontBundle = front and front:bundleID()
    -- AX inspection happens AFTER returning the input event. It cannot hold the
    -- user's mouse click while another app is slow to answer Accessibility.
    hs.timer.doAfter(0, function()
        if r.physicalSequence ~= sequence then return end
        local system = hs.axuielement.systemWideElement()
        system:setTimeout(0.05)
        local element = system:elementAtPosition(point.x, point.y)
        local role, url = attribute(element, "AXRole"), attribute(element, "AXURL")
        url = type(url) == "table" and (url.url or "") or (url and tostring(url) or "")
        if role == "AXDockItem" and (url:match("/Google%%20Chrome%.app/?$") or url:match("/Google Chrome%.app/?$")) then
            humanRequest(CHROME, "dock", plan)
            handleHumanChrome()
        elseif frontBundle == "com.openai.codex" then
            for _ = 1, 3 do
                if REVEAL[attribute(element, "AXTitle")] or REVEAL[attribute(element, "AXDescription")] then
                    humanRequest(FINDER, "reveal", plan)
                    local app = hs.application.frontmostApplication()
                    if app and app:bundleID() == FINDER then
                        local w = app:focusedWindow()
                        if normal(w) then move(w, plan, "review", "physical_finder_reveal") end
                        r.pendingHuman = nil
                    end
                    return
                end
                element = attribute(element, "AXParent")
                if not element then break end
            end
        end
        -- A real click may intentionally focus an automation window. That
        -- screen becomes the user's screen too; programmatic focus does not.
        hs.timer.doAfter(0.06, function()
            if r.physicalSequence == sequence then
                r.cachedReviewPlan = hs._codexComputerUseSidecar.placementForIntent("review")
            end
        end)
    end)
    return false -- never consume, modify, or synthesize the user's input
end):start()
r.appWatcher = hs.application.watcher.new(function(_, event, app)
    if not enabled() then return end
    if event == hs.application.watcher.deactivated and app:bundleID() == CHROME then
        hs.timer.doAfter(0, r.restorePersonalChromeMain)
        return
    end
    if event ~= hs.application.watcher.activated then return end
    local request = r.pendingHuman
    if not request or request.expires < hs.timer.secondsSinceEpoch() then return end
    if app:bundleID() == CHROME then
        hs.timer.doAfter(0.06, handleHumanChrome)
    elseif app:bundleID() == FINDER and request.bundle == FINDER then
        local w = app:focusedWindow()
        if normal(w) then
            move(w, request.plan, "review", "physical_finder_reveal")
            r.pendingHuman = nil
        end
    end
end):start()
r.chromeFilter = hs.window.filter.new(false):setAppFilter("Google Chrome", { visible = true, allowRoles = "AXStandardWindow" })
r.chromeFilter:subscribe({ [hs.window.filter.windowCreated] = function()
    if r.pendingHuman then hs.timer.doAfter(0.08, handleHumanChrome) end
    if r.mainTimer then r.mainTimer:stop() end
    r.mainTimer = hs.timer.doAfter(0.2, r.restorePersonalChromeMain)
end })
r.finderFilter = hs.window.filter.new(false):setAppFilter("Finder", { visible = true, allowRoles = "AXStandardWindow" })
r.finderFilter:subscribe({ [hs.window.filter.windowCreated] = function(w)
    local request = r.pendingHuman
    local front = hs.application.frontmostApplication()
    if enabled() and request and request.bundle == FINDER
        and request.expires >= hs.timer.secondsSinceEpoch() and front and front:bundleID() == FINDER
        and normal(w) and w:application():bundleID() == FINDER then
        move(w, request.plan, "review", "physical_finder_reveal_created")
        r.pendingHuman = nil
    end
end })
r.focusFilter = hs.window.filter.new()
r.focusFilter:subscribe({ [hs.window.filter.windowFocused] = function(w)
    if not owned(w, "automation") then
        r.cachedReviewPlan = hs._codexComputerUseSidecar.placementForIntent("review")
    end
end, [hs.window.filter.windowDestroyed] = function(w)
    local id = w:id()
    if id then
        r.owners[id] = nil
        if r.personalChromeId == id then r.personalChromeId = nil end
    end
end })
log({ type = "routing_started", physicalInputTapEnabled = r.tap:isEnabled() })
return r
