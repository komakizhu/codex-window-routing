-- Run inside Hammerspoon's Lua runtime; the module under test receives a fake
-- hs environment. No real settings, windows, input, menus, or files are changed.
local modulePath = assert(..., "pass the path to computer_use_sidecar.lua")
local PLACEMENT_KEY = "codexComputerUseSidecarPlacement"
local ENABLED_KEY = "codexComputerUseSidecarEnabled"

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

local function equal(actual, expected, message)
    assert(actual == expected, (message or "unexpected value")
        .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function screen(uuid, name, id)
    return {
        getUUID = function() return uuid end,
        name = function() return name end,
        id = function() return id end,
        frame = function() return { x = id == 1 and 0 or 400, y = id == 1 and 0 or 1080, w = 1366, h = 1024 } end,
    }
end

local function fixture(savedSettings)
    local a, b = screen("A", "Test A", 1), screen("B", "Test B", 2)
    local state = {
        screens = { a, b }, settings = copy(savedSettings or {}),
        filters = {}, screenWatchers = {}, appWatchers = {}, timers = {},
        windows = {}, visible = {}, moves = {}, logs = {}, now = 100,
        taskRequests = {}, chromeInstalled = true,
        mouse = { x = 100, y = 100 },
    }
    local function forbidden() error("the module attempted to activate or focus a window") end
    local frontmost = {
        bundleID = function() return "test.user.app" end,
        pid = function() return 10 end,
        focusedWindow = function() return state.focus end,
        activate = forbidden,
    }
    function state.setFocus(display)
        state.focus = display and {
            id = function() return 100 end,
            screen = function() return display end,
            application = function() return frontmost end,
        } or nil
    end
    state.setFocus(a)

    local function watcher(list, callback)
        local item = { active = false, callback = callback }
        function item:start() self.active = true; return self end
        function item:stop() self.active = false; return self end
        list[#list + 1] = item
        return item
    end

    local fake = {
        configdir = "/unused",
        settings = {
            get = function(key) return copy(state.settings[key]) end,
            set = function(key, value) state.settings[key] = copy(value) end,
        },
        application = {
            get = function(bundle)
                assert(bundle == "com.google.Chrome")
                return state.chromeApp
            end,
            pathForBundleID = function(bundle)
                assert(bundle == "com.google.Chrome")
                return state.chromeInstalled and "/Applications/Google Chrome.app" or nil
            end,
            frontmostApplication = function() return frontmost end,
            watcher = { activated = "activated", new = function(callback)
                return watcher(state.appWatchers, callback)
            end },
        },
        screen = {
            allScreens = function()
                local list = {}
                for _, display in ipairs(state.screens) do list[#list + 1] = display end
                return list
            end,
            watcher = { new = function(callback)
                return watcher(state.screenWatchers, callback)
            end },
        },
        window = {
            get = function(id) return state.windows[id] end,
            allWindows = function() return state.visible end,
            focusedWindow = function() return state.fallback end,
            filter = {},
        },
        mouse = { absolutePosition = function() return copy(state.mouse) end },
        timer = { secondsSinceEpoch = function() return state.now end },
        task = { new = function(path, callback, arguments)
            state.taskRequests[#state.taskRequests + 1] = { path = path, arguments = arguments }
            return { start = function() callback(0, "", ""); return true end }
        end },
        json = { encode = function(record)
            state.logs[#state.logs + 1] = copy(record)
            return "{}"
        end },
        menubar = {},
        printf = function(message) error(message) end,
    }
    for _, event in ipairs({ "windowCreated", "windowMoved", "windowOnScreen",
        "windowTitleChanged", "windowFocused" }) do fake.window.filter[event] = event end
    function fake.window.filter.new()
        local filter = { events = {} }
        function filter:setAppFilter() return self end
        function filter:subscribe(events) self.events = events; return self end
        function filter:unsubscribeAll() self.events = {}; return self end
        function filter:getWindows() return state.visible end
        state.filters[#state.filters + 1] = filter
        return filter
    end
    function fake.timer.doAfter(delay, callback)
        local timer = { delay = delay, callback = callback }
        function timer:stop() self.cancelled = true end
        state.timers[#state.timers + 1] = timer
        return timer
    end
    function fake.menubar.new()
        local menu = {}
        function menu:setTitle(title) self.title = title; return self end
        function menu:setTooltip(tooltip) self.tooltip = tooltip; return self end
        function menu:setMenu(builder) self.builder = builder; return self end
        state.menu = menu
        return menu
    end
    local env = setmetatable({ hs = fake, io = { open = function()
        return { write = function() end, flush = function() end, close = function() end }
    end } }, { __index = _G })

    function state.load()
        assert(loadfile(modulePath, "t", env))()
        state.runtime = fake._codexComputerUseSidecar
        return state.runtime
    end
    function state.snapshot() return state.runtime.placementSnapshot() end
    function state.flush()
        local rounds = 0
        while #state.timers > 0 do
            rounds = rounds + 1
            assert(rounds < 30, "timer/movement loop")
            local pending = state.timers
            state.timers = {}
            for _, timer in ipairs(pending) do
                if not timer.cancelled then
                    state.now = state.now + timer.delay
                    timer.callback()
                end
            end
        end
    end
    function state.item(title, items)
        for _, item in ipairs(items or state.menu.builder()) do
            if item.title == title then return item end
        end
        error("missing menu item: " .. title)
    end
    function state.fixed(title)
        state.item(title, state.item("固定使用指定副屏").menu).fn()
        state.flush()
    end
    function state.follow()
        state.item("跟随焦点，使用另一块屏").fn()
        state.flush()
    end
    function state.emitWindow(event, window)
        for _, filter in ipairs(state.filters) do
            if filter.events[event] then filter.events[event](window) end
        end
    end
    function state.emitFocus()
        state.emitWindow("windowFocused", state.focus)
        for _, item in ipairs(state.appWatchers) do
            if item.active then item.callback(nil, "activated") end
        end
    end
    function state.emitScreen()
        for _, item in ipairs(state.screenWatchers) do
            if item.active then item.callback() end
        end
        state.flush()
    end
    function state.window(id, title, bundle, subrole)
        local owner = {
            bundleID = function() return bundle end,
            pid = function() return 20 end,
            activate = forbidden,
        }
        local window = { display = a }
        function window:id() return id end
        function window:title() return title end
        function window:application() return owner end
        function window:screen() return self.display end
        function window:role() return "AXWindow" end
        function window:subrole() return subrole or "AXSystemDialog" end
        function window:frame() return { x = 10, y = 10, w = 300, h = 200 } end
        function window:moveToScreen(target)
            state.moves[#state.moves + 1] = { id = id, target = target:getUUID() }
            self.display = target
            return self
        end
        window.focus, window.raise = forbidden, forbidden
        state.windows[id] = window
        state.visible[#state.visible + 1] = window
        return window
    end
    state.a, state.b = a, b
    state.load()
    return state
end

local results = {}
local function test(name, body)
    local ok, err = pcall(body)
    results[#results + 1] = { name = name, passed = ok, error = not ok and tostring(err) or nil }
end

test("default_tracks_focus_not_mouse", function()
    local s = fixture()
    equal(s.snapshot().targetScreenUUID, "B")
    equal(s.item("跟随焦点，使用另一块屏").checked, true)
    s.mouse = { x = 2000, y = 2000 }
    equal(s.snapshot().targetScreenUUID, "B")
    s.setFocus(s.b)
    equal(s.snapshot().targetScreenUUID, "A")
    s.fallback = s.window(90, "background", "test.background")
    s.setFocus(nil)
    equal(s.snapshot().reason, "focused_window_unavailable")
end)

test("fixed_ignores_focus_and_supports_more_screens", function()
    local s = fixture()
    s.fixed("Test B")
    s.setFocus(nil)
    equal(s.snapshot().targetScreenUUID, "B")
    s.setFocus(s.b)
    s.screens[3] = screen("C", "Test C", 3)
    s.emitFocus()
    equal(#s.timers, 0, "fixed mode should ignore focus events")
    equal(s.snapshot().targetScreenUUID, "B")
    s.follow()
    equal(s.snapshot().reason, "requires_exactly_two_screens")
end)

test("menu_selection_and_preferences_survive_restart", function()
    local s = fixture()
    s.fixed("Test A")
    equal(s.settings[PLACEMENT_KEY].fixedScreenUUID, "A")
    local restarted = fixture(s.settings)
    restarted.setFocus(nil)
    equal(restarted.snapshot().targetScreenUUID, "A")
    equal(restarted.item("固定使用指定副屏").checked, true)
    equal(restarted.item("Test A", restarted.item("固定使用指定副屏").menu).checked, true)
    restarted.follow()
    local again = fixture(restarted.settings)
    equal(again.snapshot().placementMode, "opposite_focus")
    equal(again.snapshot().targetScreenUUID, "B")
    equal(again.settings[PLACEMENT_KEY].fixedScreenUUID, "A", "remember last fixed choice")
end)

test("disconnect_pauses_and_reconnect_uses_uuid", function()
    local s = fixture()
    s.fixed("Test B")
    local preview = s.window(1, "Computer Use", "com.openai.codex")
    local personal = s.window(2, "Computer Use", "com.apple.Safari")
    s.screens = { s.a }
    s.emitScreen()
    equal(#s.moves, 0)
    equal(s.snapshot().reason, "fixed_screen_not_connected")
    equal(s.item("Test B（未连接，暂停移动）", s.item("固定使用指定副屏").menu).checked, true)
    s.b = screen("B", "Reconnected B", 99)
    s.screens = { s.b, s.a }
    s.emitScreen()
    equal(preview:screen():getUUID(), "B")
    equal(personal:screen():getUUID(), "A")
    equal(s.settings[PLACEMENT_KEY].fixedScreenUUID, "B")
    equal(s.item("Reconnected B", s.item("固定使用指定副屏").menu).checked, true)
end)

test("mode_changes_move_only_codex_preview_and_controls", function()
    local s = fixture()
    local preview = s.window(1, "Computer Use", "com.openai.codex")
    local controls = s.window(2, "Computer Use Controls", "com.openai.codex")
    local main = s.window(3, "Codex", "com.openai.codex", "AXStandardWindow")
    local safari = s.window(4, "Computer Use", "com.apple.Safari")
    local obsidian = s.window(5, "Notes", "md.obsidian", "AXStandardWindow")
    s.emitWindow("windowCreated", preview)
    s.emitWindow("windowCreated", controls)
    s.emitWindow("windowCreated", safari)
    s.flush()
    equal(#s.moves, 2)
    s.fixed("Test A")
    equal(preview:screen():getUUID(), "A")
    equal(controls:screen():getUUID(), "A")
    s.setFocus(s.b)
    s.emitFocus()
    s.flush()
    equal(#s.moves, 4)
    s.follow()
    s.setFocus(s.a)
    s.emitFocus()
    s.flush()
    equal(preview:screen():getUUID(), "B")
    equal(controls:screen():getUUID(), "B")
    equal(#s.moves, 6)
    s.emitWindow("windowMoved", preview)
    s.flush()
    equal(#s.moves, 6, "already placed window must not move again")
    for _, window in ipairs({ main, safari, obsidian }) do equal(window:screen():getUUID(), "A") end
end)

test("pause_reload_and_resume_keep_fixed_choice", function()
    local s = fixture()
    s.fixed("Test B")
    s.item("暂停自动分配").fn()
    local preview = s.window(1, "Computer Use", "com.openai.codex")
    s.load()
    s.flush()
    equal(s.runtime.enabled, false)
    equal(s.snapshot().targetScreenUUID, "B")
    equal(s.menu.title, "CU副屏 ○")
    equal(#s.moves, 0)
    s.item("开启自动分配").fn()
    s.flush()
    equal(preview:screen():getUUID(), "B")
    equal(s.settings[ENABLED_KEY], true)
    equal(s.settings[PLACEMENT_KEY].mode, "fixed_screen")
end)

test("same_name_screens_have_separate_uuid_choices", function()
    local s = fixture()
    s.a, s.b = screen("A", "Same", 4), screen("B", "Same", 8)
    s.screens = { s.b, s.a }
    s.fixed("Same（编号 8）")
    equal(s.snapshot().targetScreenUUID, "B")
    s.b = screen("B", "Same", 10)
    s.screens = { s.a, s.b }
    equal(s.snapshot().targetScreenUUID, "B")
    equal(s.item("Same（编号 10）", s.item("固定使用指定副屏").menu).checked, true)
end)

test("invalid_preferences_do_not_guess_a_fixed_screen", function()
    local invalid = fixture({ [PLACEMENT_KEY] = "invalid" })
    equal(invalid.snapshot().placementMode, "opposite_focus")
    local missing = fixture({ [PLACEMENT_KEY] = { mode = "fixed_screen" } })
    equal(missing.snapshot().reason, "fixed_screen_not_configured")
    equal(missing.snapshot().targetScreenUUID, nil)
end)

test("pending_move_uses_latest_mode", function()
    local s = fixture()
    local preview = s.window(1, "Computer Use", "com.openai.codex")
    s.emitWindow("windowCreated", preview)
    s.item("Test A", s.item("固定使用指定副屏").menu).fn()
    s.flush()
    equal(preview:screen():getUUID(), "A")
    equal(#s.moves, 0, "old focus-mode target must not be used after changing mode")
    equal(s.snapshot().targetScreenUUID, "A")
end)

test("new_window_bounds_use_selected_screen_and_respect_pause", function()
    local s = fixture()
    local route = s.runtime.newWindowPlacement()
    equal(route.enabled, true)
    equal(route.targetScreenUUID, "B")
    equal(route.bounds.left, 440)
    equal(route.bounds.top, 1120)
    equal(route.bounds.focused, false)
    equal(route.bounds.state, "normal")
    s.fixed("Test A")
    equal(s.runtime.newWindowPlacement().bounds.top, 40)
    s.item("暂停自动分配").fn()
    equal(s.runtime.newWindowPlacement().reason, "auto_assignment_paused")
    equal(s.runtime.newWindowPlacement().bounds, nil)
end)

test("a_queued_preview_move_is_cancelled_when_the_user_pauses", function()
    local s=fixture()
    local w=s.window(501,"Computer Use","com.openai.codex")
    s.emitWindow("windowCreated",w)
    s.item("暂停自动分配").fn()
    s.flush()
    equal(#s.moves,0);equal(w:screen():getUUID(),"A")
end)

test("live_safety_pause_blocks_pending_moves_new_placements_and_cold_start", function()
    local s=fixture()
    local w=s.window(502,"Computer Use","com.openai.codex")
    s.emitWindow("windowCreated",w)
    s.settings.codexComputerUseSafetySuspended=true
    s.flush()
    equal(#s.moves,0);equal(s.runtime.newWindowPlacement().enabled,false)
    equal(s.runtime.newWindowPlacement().reason,"auto_assignment_paused")
    equal(s.runtime.prepareChrome().reason,"auto_assignment_paused");equal(#s.taskRequests,0)
    local first=s.menu.builder()[1];equal(first.disabled,true)
    equal(s.settings.codexComputerUseSafetySuspended,true)
end)

test("a_saved_safety_pause_never_starts_preview_observers", function()
    local s=fixture({codexComputerUseSafetySuspended=true,[ENABLED_KEY]=true})
    equal(#s.filters,0);equal(#s.screenWatchers,0);equal(#s.appWatchers,0)
    equal(s.runtime.newWindowPlacement().enabled,false)
    equal(s.menu.title,"CU 暂停排查")
    equal(s.settings.codexComputerUseSafetySuspended,true)
end)

test("chrome_cold_start_opens_no_window_and_deduplicates", function()
    local s = fixture()
    equal(s.runtime.prepareChrome().chromeState, "starting")
    equal(s.runtime.prepareChrome().chromeState, "starting")
    equal(#s.taskRequests, 1)
    equal(s.taskRequests[1].path, "/usr/bin/open")
    local arguments = s.taskRequests[1].arguments
    equal(table.concat(arguments, "|"), "-g|-a|/Applications/Google Chrome.app|--args|--no-startup-window")
    s.chromeApp = { pid = function() return 50 end }
    equal(s.runtime.prepareChrome().chromeState, "running")
    equal(#s.taskRequests, 1, "an existing Chrome must not be relaunched")
end)

test("chrome_start_respects_pause_disconnect_and_missing_app", function()
    local s = fixture()
    s.item("暂停自动分配").fn()
    equal(s.runtime.prepareChrome().reason, "auto_assignment_paused")
    s.item("开启自动分配").fn()
    s.fixed("Test B")
    s.screens = { s.a }
    equal(s.runtime.prepareChrome().reason, "fixed_screen_not_connected")
    s.screens = { s.a, s.b }
    s.chromeInstalled = false
    equal(s.runtime.prepareChrome().reason, "chrome_not_installed")
    equal(#s.taskRequests, 0)
end)

test("workspace_record_survives_module_reload_but_not_a_different_chrome_process", function()
    local s = fixture()
    s.chromeApp = { pid = function() return 50 end }
    s.runtime.rememberChromeWorkspace({ windowId = 101, tabId = 102, groupId = 205, extensionInstanceId = "profile-one" })
    s.load()
    equal(s.runtime.newWindowPlacement().chromeWorkspace.tabId, 102)
    s.chromeApp = { pid = function() return 51 end }
    equal(s.runtime.newWindowPlacement().chromeWorkspace, nil)
end)

test("review_uses_focused_screen_even_when_automation_screen_is_fixed", function()
    local s = fixture()
    s.fixed("Test B")
    equal(s.runtime.placementForIntent("automation").targetScreenUUID, "B")
    local review = s.runtime.placementForIntent("review")
    equal(review.intent, "review")
    equal(review.targetScreenUUID, "A")
    equal(review.bounds.top, 40)
    equal(review.bounds.focused, false)
    s.setFocus(s.b)
    equal(s.runtime.placementForIntent("review").targetScreenUUID, "B")
    equal(s.runtime.placementForIntent("automation").targetScreenUUID, "B")
end)

local passed = 0
for _, result in ipairs(results) do if result.passed then passed = passed + 1 end end
return { passed = passed, total = #results, cases = results }
