-- Simulated routing tests. No real input, apps, windows, settings, or files.
local path = assert(...)
local function equal(a, b, message) assert(a == b, (message or "not equal") .. ": " .. tostring(a) .. " ~= " .. tostring(b)) end
local function fixture()
    local s = { now = 10, enabled = true, windows = {}, apps = {}, timers = {}, filters = {}, moves = {}, focusCalls = 0 }
    local function display(id) return { getUUID = function() return id end,
        frame = function() return {x=id=="A" and 0 or 1200,y=0,w=1200,h=900} end } end
    s.a, s.b = display("A"), display("B")
    function s.app(bundle)
        if s.apps[bundle] then return s.apps[bundle] end
        s.nextPid = (s.nextPid or 100) + 1
        local app = { bundle = bundle, process = s.nextPid }
        function app:bundleID() return self.bundle end
        function app:pid() return self.process end
        function app:allWindows() local out = {}; for _,w in pairs(s.windows) do if w:application()==self then out[#out+1]=w end end; return out end
        function app:focusedWindow() return self.focused end
        function app:selectMenuItem()
            s.menuCalls = (s.menuCalls or 0) + 1
            local w = s.window(900 + s.menuCalls, self.bundle, s.b)
            self.focused = w
            s.emitCreated(w)
            return true
        end
        s.apps[bundle] = app
        return app
    end
    function s.window(id, bundle, screen, processApp)
        local app = processApp or s.app(bundle)
        local w = { display = screen, owner = app }
        function w:id() return id end
        function w:role() return "AXWindow" end
        function w:subrole() return "AXStandardWindow" end
        function w:application() return self.owner end
        function w:screen() return self.display end
        function w:moveToScreen(target) self.display = target; s.moves[#s.moves+1] = id; return self end
        function w:becomeMain() self.owner.main = self; return self end
        function w:focus() s.focusCalls=s.focusCalls+1; s.front=self.owner; self.owner.focused=self; return self end
        s.windows[id] = w
        return w
    end
    s.front = s.app("com.openai.codex")
    local fake = {
        configdir = "/unused", printf = function() end,
        json = { encode = function() return "{}" end },
        timer = { secondsSinceEpoch = function() return s.now end },
        application = { get = function(bundle) return s.apps[bundle] end,
            applicationsForBundleID = function(bundle)
                local out={};if s.apps[bundle] then out[#out+1]=s.apps[bundle] end
                for _,a in ipairs(s.otherInstances or {}) do if a:bundleID()==bundle then out[#out+1]=a end end
                return out
            end,
            frontmostApplication = function() return s.front end, watcher = { activated = "activated" } },
        screen = { allScreens = function() return {s.a,s.b} end },
        window = { get = function(id) return s.windows[id] end, filter = { windowCreated="created", windowFocused="focused",windowDestroyed="destroyed" } },
        eventtap = { event = { types={ leftMouseDown="mouse",keyDown="key" }, properties={eventSourceUnixProcessID="pid",eventSourceStateID="state"} } },
        keycodes = { map = { n = 45 } },
        axuielement = { systemWideElement = function()
            return { setTimeout=function() end, elementAtPosition=function() return s.element end }
        end },
        fs = { attributes = function()return "directory" end },
        osascript = { applescript = function(script)
            s.finderScript=script;s.finderCalls=(s.finderCalls or 0)+1
            if s.denyFinder then return false,nil,{NSAppleScriptErrorNumber=-1743} end
            s.window(90,"com.apple.finder",s.b)
            return true,90
        end },
    }
    fake._codexComputerUseSidecar = { enabled = true, placementForIntent = function(intent)
        return { enabled=s.enabled, intent=intent, targetScreenUUID=intent=="automation" and "B" or "A",
            bounds=s.enabled and {left=intent=="automation" and 1200 or 0,top=0,width=800,height=600} or nil,
            reason=not s.enabled and "auto_assignment_paused" or nil }
    end }
    function fake.timer.doAfter(delay, fn)
        local t={fn=fn,delay=delay};function t:stop() self.stopped=true end;s.timers[#s.timers+1]=t;return t
    end
    function fake.application.watcher.new(fn)
        s.appEvent=fn;return {start=function(self)return self end,stop=function()end}
    end
    function fake.window.filter.new()
        local f={};function f:setAppFilter()return self end;function f:subscribe(events)self.events=events;return self end
        function f:unsubscribeAll()self.events={}end;s.filters[#s.filters+1]=f;return f
    end
    function fake.eventtap.new(_, fn)
        s.input=fn;return {start=function(self)return self end,stop=function()end,isEnabled=function()return true end}
    end
    function s.flush()
        local rounds=0
        while #s.timers>0 do
            rounds=rounds+1;assert(rounds<20,"timer loop")
            local timers=s.timers;s.timers={}
            for _,t in ipairs(timers)do if not t.stopped then s.now=s.now+t.delay;t.fn()end end
        end
    end
    function s.emitCreated(w)
        for _,f in ipairs(s.filters)do if f.events and f.events.created then f.events.created(w)end end
    end
    function s.activate(bundle)
        s.front=s.app(bundle);s.appEvent(nil,"activated",s.front)
    end
    function s.click(kind, pid, state)
        local data={pid=pid or 0,state=state or 1}
        return s.input({getProperty=function(_,key)return data[key]end,getType=function()return kind or "mouse"end,
            getFlags=function()return{cmd=true}end,getKeyCode=function()return 45 end,location=function()return{x=5,y=5}end})
    end
    function s.node(values)
        return { attributeValue=function(_,key)return values[key]end }
    end
    local env=setmetatable({hs=fake,io={open=function()return{write=function()end,close=function()end}end}},{__index=_G})
    function s.reload() assert(loadfile(path,"t",env))() end
    s.reload()
    s.r=fake._codexExternalWindowRouter;s.hs=fake
    return s
end
local cases={}
local function test(name,fn)local ok,err=pcall(fn);cases[#cases+1]={name=name,passed=ok,error=not ok and tostring(err)or nil}end
test("automation_claims_only_the_new_window",function()
    local s=fixture();local old=s.window(1,"app.target",s.a)
    local token=s.r.begin("automation","app.target");local new=s.window(2,"app.target",s.a)
    equal(s.r.finish(token,2),true);equal(new:screen():getUUID(),"B");equal(old:screen():getUUID(),"A");equal(s.focusCalls,0)
end)
test("automation_refuses_existing_personal_window",function()
    local s=fixture();local old=s.window(1,"app.target",s.a);local token=s.r.begin("automation","app.target")
    local ok,reason=s.r.finish(token,1);equal(ok,nil);equal(reason,"existing_or_unrelated_window_not_claimed");equal(#s.moves,0)
end)
test("ambiguous_or_expired_open_does_not_guess",function()
    local s=fixture();local token=s.r.begin("automation","app.target")
    s.window(1,"app.target",s.a);s.window(2,"app.target",s.a)
    local ok,reason=s.r.finish(token);equal(ok,nil);equal(reason,"new_window_not_unique");equal(#s.moves,0)
    token=s.r.begin("automation","app.target");s.now=s.now+121;equal(s.r.finish(token),nil)
end)
test("physical_input_during_open_prevents_implicit_claim",function()
    local s=fixture();local token=s.r.begin("automation","app.target")
    s.window(4,"app.target",s.a);s.click("key",0,1)
    local ok,reason=s.r.finish(token);equal(ok,nil)
    equal(reason,"user_input_during_open_requires_exact_window_id");equal(#s.moves,0)
end)
test("explicit_review_goes_to_user_screen_even_from_codex",function()
    local s=fixture();local token=s.r.begin("review","com.apple.finder")
    local w=s.window(3,"com.apple.finder",s.b);equal(s.r.finish(token,3),true);equal(w:screen():getUUID(),"A");equal(s.focusCalls,0)
end)
test("review_can_reuse_a_window_only_with_explicit_authorization",function()
    local s=fixture();s.window(3,"com.apple.finder",s.b)
    local token=s.r.begin("review","com.apple.finder");equal(s.r.finish(token,3),nil)
    token=s.r.begin("review","com.apple.finder",true);equal(s.r.finish(token,3),true)
end)
test("programmatic_mouse_or_key_events_are_never_human_open_requests",function()
    local s=fixture();s.element=s.node({AXRole="AXDockItem",AXURL={url="file:///Applications/Google%20Chrome.app/"}})
    equal(s.click("mouse",555,1),false);s.flush();equal(s.r.pendingHuman,nil)
    equal(s.click("mouse",0,0),false);s.flush();equal(s.r.pendingHuman,nil)
end)
test("physical_chrome_dock_open_uses_personal_window_and_keeps_work_on_side",function()
    local s=fixture();local work=s.window(1,"com.google.Chrome",s.b);s.r.adoptVerifiedAutomationWindow(1)
    local token=s.r.begin("review","com.google.Chrome");local personal=s.window(2,"com.google.Chrome",s.a);s.r.finish(token,2)
    s.element=s.node({AXRole="AXDockItem",AXURL={url="file:///Applications/Google%20Chrome.app/"}})
    equal(s.click("mouse",0,1),false);s.front=s.app("com.google.Chrome");s.front.focused=work;s.flush()
    equal(s.front.focused,personal);equal(work:screen():getUUID(),"B");equal(s.focusCalls,1);s.flush();equal(s.focusCalls,1)
end)
test("physical_dock_open_creates_user_window_when_only_agent_window_exists",function()
    local s=fixture();local work=s.window(1,"com.google.Chrome",s.b);s.r.adoptVerifiedAutomationWindow(1)
    s.element=s.node({AXRole="AXDockItem",AXURL={url="file:///Applications/Google%20Chrome.app/"}})
    s.click("mouse",0,1);s.front=s.app("com.google.Chrome");s.front.focused=work;s.flush()
    equal(s.menuCalls,1);equal(s.windows[901]:screen():getUUID(),"A");equal(work:screen():getUUID(),"B");equal(s.focusCalls,0)
end)
test("physical_finder_reveal_is_review_not_automation",function()
    local s=fixture();local finder=s.window(5,"com.apple.finder",s.b)
    s.element=s.node({AXTitle="Reveal in Finder"});s.click("mouse",0,1)
    s.front=s.app("com.apple.finder");s.front.focused=finder;s.flush()
    equal(finder:screen():getUUID(),"A");equal(s.r.owners[5].intent,"review");equal(s.focusCalls,0)
end)
test("agent_window_creation_restores_app_main_without_stealing_foreground",function()
    local s=fixture();local token=s.r.begin("review","com.google.Chrome");local personal=s.window(2,"com.google.Chrome",s.a);s.r.finish(token,2)
    token=s.r.begin("automation","com.google.Chrome");s.window(3,"com.google.Chrome",s.a);s.r.finish(token,3)
    equal(s.apps["com.google.Chrome"].main,personal);equal(s.front:bundleID(),"com.openai.codex");equal(s.focusCalls,0)
end)
test("pause_cancels_a_deferred_human_dock_response",function()
    local s=fixture();s.element=s.node({AXRole="AXDockItem",AXURL={url="file:///Applications/Google%20Chrome.app/"}})
    s.click("mouse",0,1);s.hs._codexComputerUseSidecar.enabled=false;s.flush()
    equal(s.r.pendingHuman,nil);equal(s.focusCalls,0);equal(s.menuCalls,nil);equal(#s.moves,0)
end)
test("move_exception_is_reported_without_touching_personal_window",function()
    local s=fixture();local personal=s.window(1,"app.target",s.a)
    local token=s.r.begin("automation","app.target");local w=s.window(2,"app.target",s.a)
    function w:moveToScreen() error("test move failure") end
    local ok,reason=s.r.finish(token,2);equal(ok,nil);equal(reason,"window_move_failed")
    equal(personal:screen():getUUID(),"A");equal(s.focusCalls,0)
end)
test("closed_window_registration_is_removed",function()
    local s=fixture();local token=s.r.begin("review","com.google.Chrome")
    local w=s.window(2,"com.google.Chrome",s.a);s.r.finish(token,2)
    for _,f in ipairs(s.filters) do if f.events.destroyed then f.events.destroyed(w) end end
    equal(s.r.personalChromeId,nil);equal(s.r.owners[2],nil)
end)
test("module_reload_preserves_an_in_flight_opening",function()
    local s=fixture();local token=s.r.begin("automation","app.target")
    local w=s.window(3,"app.target",s.a);s.reload()
    equal(s.r.finish(token),true);equal(w:screen():getUUID(),"B")
end)
test("resume_uses_the_screen_captured_before_the_dock_click",function()
    local s=fixture();local work=s.window(1,"com.google.Chrome",s.b);s.r.adoptVerifiedAutomationWindow(1)
    s.r.cachedReviewPlan={reason="auto_assignment_paused",targetScreenUUID="A"}
    s.element=s.node({AXRole="AXDockItem",AXURL={url="file:///Applications/Google%20Chrome.app/"}})
    s.click("mouse",0,1);s.front=s.app("com.google.Chrome");s.front.focused=work;s.flush()
    equal(s.windows[901]:screen():getUUID(),"A");equal(work:screen():getUUID(),"B")
end)
test("exact_window_in_a_second_application_process_is_routed",function()
    local s=fixture();local personal=s.window(1,"md.obsidian",s.a)
    local app={bundleID=function()return "md.obsidian" end,pid=function()return 999 end}
    function app:allWindows()return{ s.windows[2] }end
    local token=s.r.begin("automation","md.obsidian")
    local work=s.window(2,"md.obsidian",s.a,app);s.otherInstances={app}
    local ok,reason=s.r.finish(token,2)
    equal(ok,true,reason);equal(work:screen():getUUID(),"B")
    equal(personal:screen():getUUID(),"A");equal(s.focusCalls,0)
end)
test("finder_task_creates_only_a_new_window_at_initial_bounds",function()
    local s=fixture();local old=s.window(1,"com.apple.finder",s.a)
    equal(type(s.r.openFinderWindow),"function","dedicated Finder opener missing")
    local ok,result=s.r.openFinderWindow("automation","/test/own-folder")
    equal(ok,true);equal(result.windowId,90);equal(old:screen():getUUID(),"A")
    assert(s.finderScript:find("make new Finder window",1,true));assert(s.finderScript:find("bounds:",1,true))
    assert(not s.finderScript:find("activate",1,true));equal(s.focusCalls,0)
end)
test("finder_denial_or_pause_never_falls_back_to_an_existing_window",function()
    local s=fixture();s.window(1,"com.apple.finder",s.a);s.denyFinder=true
    equal(type(s.r.openFinderWindow),"function","dedicated Finder opener missing")
    local ok,result=s.r.openFinderWindow("automation","/test/own-folder")
    equal(ok,nil);equal(result.reason,"finder_create_failed");equal(#s.moves,0)
    s.hs._codexComputerUseSidecar.enabled=false;s.enabled=false
    ok,result=s.r.openFinderWindow("automation","/test/own-folder")
    equal(ok,nil);equal(result.reason,"auto_assignment_paused");equal(s.finderCalls,1)
end)
local passed=0;for _,case in ipairs(cases)do if case.passed then passed=passed+1 end end
return{passed=passed,total=#cases,cases=cases}
