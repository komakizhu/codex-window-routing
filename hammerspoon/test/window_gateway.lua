-- Run in an isolated Lua environment; no real windows or input are used.
local path = assert(...)
local function eq(a,b) assert(a==b,tostring(a).." ~= "..tostring(b)) end
local function fixture()
    local s={now=100,windows={},moves={},settings={},timers={},periodic={},focusCalls=0,events={},files={}}
    local function screen(id,x) return {getUUID=function()return id end,id=function()return x+1 end,
        fullFrame=function()return{x=x,y=s.layoutY or 0,w=1200,h=900}end,
        frame=function()return{x=x,y=s.layoutY or 0,w=1200,h=900}end} end
    s.a,s.b=screen("main",0),screen("side",1200);s.screens={s.a,s.b}
    local user={pid=function()return 10 end,bundleID=function()return"user.app"end}
    local apps={}
    local nativeLauncher=(os.getenv("HOME") or "").."/.codex/window-routing/current/bin/native-app-launcher"
    local realJsonEncode,realJsonDecode=hs.json.encode,hs.json.decode
    function s.app(bundle,pid,appPath)
        local a={bundleID=function()return bundle end,pid=function()return pid end,
            path=function()return appPath or "/Applications/Test.app"end,
            isRunning=function()return true end}
        function a:allWindows()local t={};for _,w in pairs(s.windows)do if w:application()==self then t[#t+1]=w end end;return t end
        apps[#apps+1]=a;return a
    end
    function s.window(id,app,display)
        local w={display=display}
        function w:id()return id end;function w:application()return app end
        function w:role()return"AXWindow"end;function w:subrole()return"AXStandardWindow"end
        function w:screen()return self.display end
        function w:frame()return{x=self.display==s.a and 40 or 1240,y=40,w=1000,h=700}end
        function w:moveToScreen(target)self.display=target;s.moves[#s.moves+1]=id;return self end
        function w:focus()s.focusCalls=s.focusCalls+1;error("must not focus")end
        s.windows[id]=w;return w
    end
    s.userWindow=s.window(1,user,s.a);s.focus=s.userWindow
    function user:focusedWindow()return s.focus end
    s.front=user
    local fake={configdir="/unused",settings={get=function(k)return s.settings[k]end},
        application={frontmostApplication=function()return s.front end,
            applicationsForBundleID=function(bundle)local t={};for _,a in ipairs(apps)do if a:bundleID()==bundle then t[#t+1]=a end end;return t end,
            applicationForPID=function(pid)for _,a in ipairs(apps)do if a:pid()==pid then return a end end end},
        screen={allScreens=function()return s.screens end},
        window={get=function(id)return s.windows[id]end},
        timer={secondsSinceEpoch=function()return s.now end},
        json={encode=function(v)s.events[#s.events+1]=v;return realJsonEncode(v)end,
            decode=function(value)
                if value=="worker" then return{bundleID="local.codex.ObsidianWorkspace",backgroundProtocolVersion=1,
                    appPath="/unused/codex-obsidian-worker/build-1/Private.app",
                    executable="/unused/codex-obsidian-worker/build-1/Private.app/Contents/MacOS/Obsidian"}end
                return realJsonDecode(value)
            end},
        fs={mkdir=function()return true end,attributes=function(file,key)
            if file==nativeLauncher and key then return"file"end
            if key then return (file:sub(-9)=="/Obsidian" or file:find("/Contents/Frameworks/Obsidian Helper",1,true))
                and "file" or "directory"
                else return{ino=1,dev=1}end end},
        osascript={applescript=function(script)
            s.script=script;if s.denyFinder then return false,nil,{code=-1743}end
            local a=s.app("com.apple.finder",50)
            -- Finder restores folder geometry after applying make-properties.
            -- A subsequent explicit bounds assignment is needed in practice.
            s.window(55,a,script:find("set bounds of newWindow",1,true) and s.b or s.a)
            return true,{55,"/own/test",2}
        end}}
    fake._codexComputerUseSidecar={enabled=true,placement={mode="fixed_screen",fixedScreenUUID="side"}}
    fake.eventtap={event={types={leftMouseDown=1,keyDown=2},properties={eventSourceUnixProcessID=3,eventSourceStateID=4}}}
    function fake.eventtap.new(_,callback)s.input=callback;return{start=function(self)return self end,stop=function()end}end
    function fake.timer.doAfter(_,fn)s.timers[#s.timers+1]=fn;return{stop=function()end}end
    function fake.timer.doEvery(_,fn)
        local timer={stopped=false};function timer:stop()self.stopped=true end
        s.periodic[#s.periodic+1]={fn=fn,timer=timer};return timer
    end
    fake.task={new=function(executable,exited,stream,args)
        if executable==nativeLauncher then
            local action,value=args[1],args[2]
            local task={running=false,isRunning=function(self)return self.running end,
                start=function(self)
                    self.running=true
                    if action=="resolve" then
                        stream(self,realJsonEncode(s.resolvedIdentity or {appPath="/Applications/Telegram.app",
                            bundleID="ru.keepcoder.Telegram",displayName="Telegram"}),"")
                    elseif action=="launch" then
                        local bundleID=s.launchedBundleID or "ru.keepcoder.Telegram"
                        local pid=s.launchedPID or 70
                        local app=s.app(bundleID,pid,value)
                        s.window(71,app,s.a)
                        if s.extraNativeWindow then s.window(72,app,s.a) end
                        stream(self,realJsonEncode({ok=true,appPath=value,bundleID="ru.keepcoder.Telegram",
                            displayName="Telegram",pid=pid}),"")
                    end
                    self.running=false;exited(0);return true
                end,terminate=function(self)self.running=false end}
            return task
        end
        if executable~="/usr/bin/sandbox-exec" then
            s.preparationCalls=s.preparationCalls or {};s.preparationCalls[#s.preparationCalls+1]={executable=executable,args=args}
            if executable=="/bin/cp" then s.copyArgs=args end
            if executable=="/usr/bin/plutil" then s.identityArgs=args end
            if executable=="/usr/bin/codesign" then
                if args[1]=="--force" then s.signArgs=args else s.verifyArgs=args end
            end
            local prep={running=false,isRunning=function(self)return self.running end,
                start=function(self)self.running=true;exited(0);self.running=false;return self end}
            s.copyTask=prep;return prep
        end
        s.nextPid=(s.nextPid or 59)+1;local pid=s.nextPid;s.taskArgs=args;s.running=false
        local task={pid=function()return pid end,isRunning=function()return s.running end,
            start=function(self)s.running=true;return self end,
            terminate=function()s.running=false;s.terminated=true;exited(15)end}
        s.task=task;return task
    end}
    function s.flush()local q=s.timers;s.timers={};for _,f in ipairs(q)do f()end end
    local env=setmetatable({hs=fake,os={getenv=os.getenv,rename=function(from,to)
        s.files[to]=s.files[from];s.files[from]=nil;return true end},io={open=function(file)
        return{read=s.workerInstalled and file:find("worker.json",1,true) and function()return"worker"end or nil,
            write=function(_,value)s.files[file]=value end,close=function()end}end}},{__index=_G})
    s.r=assert(loadfile(path,"t",env))();s.hs=fake
    return s
end
local results={}
local function test(name,fn)local ok,err=pcall(fn);results[#results+1]={name=name,passed=ok,error=not ok and tostring(err)or nil}end
test("only_an_explicit_supported_open_is_dispatched",function()
    local s=fixture();local a,e=s.r.open("automation","unknown",{});eq(a,nil);eq(e,"unsupported_application")
    eq(#s.moves,0);eq(s.focusCalls,0)
end)
test("gateway_supplies_initial_side_bounds_before_chrome_creation",function()
    local s=fixture();local p=assert(s.r.open("automation","chrome",{}))
    eq(p.kind,"browser");eq(p.placement.bounds.left,1240);eq(p.placement.bounds.focused,false);eq(#s.moves,0)
end)
test("browser_ids_are_registered_without_guessing_native_windows_during_user_input",function()
    local s=fixture();local p=assert(s.r.open("automation","chrome",{browserBaselineIDs={100}}))
    s.physicalSequence=20;s.r.physicalSequence=20
    eq(type(s.r.finishBrowser),"function")
    local ok,result=s.r.finishBrowser(p.requestID,{windowId=101,tabId=102,extensionInstanceId="test",bounds=p.placement.bounds})
    eq(ok,true);eq(result.windowId,101);eq(#s.moves,0);eq(s.focusCalls,0)
end)
test("browser_commit_refuses_old_ids_wrong_bounds_or_a_focused_window",function()
    for _,change in ipairs({"old","position","focus"})do
        local s=fixture();local p=assert(s.r.open("automation","chrome",{browserBaselineIDs={100}}))
        local b={};for k,v in pairs(p.placement.bounds)do b[k]=v end
        if change=="position" then b.left=0 end;if change=="focus" then b.focused=true end
        eq(type(s.r.finishBrowser),"function")
        eq(s.r.finishBrowser(p.requestID,{windowId=change=="old" and 100 or 101,tabId=102,extensionInstanceId="test",bounds=b}),nil)
        eq(#s.moves,0)
    end
end)
test("browser_preflight_keeps_the_screen_ticket_and_exact_connection",function()
    local s=fixture();local p=assert(s.r.open("automation","chrome",{browserBaselineIDs={100},browserExtensionInstanceId="connection"}))
    eq(p.extensionInstanceId,"connection")
    eq(s.r.checkBrowserRequest(p.requestID,"connection",p.placement).ok,true)
    eq(s.r.checkBrowserRequest(p.requestID,"different",p.placement),nil)
    local changed={intent="automation",targetScreenUUID=p.placement.targetScreenUUID,bounds={}}
    for k,v in pairs(p.placement.bounds)do changed.bounds[k]=v end
    changed.bounds.left=0;eq(s.r.checkBrowserRequest(p.requestID,"connection",changed),nil)
    eq(s.r.finishBrowser(p.requestID,{windowId=101,tabId=102,extensionInstanceId="different",bounds=p.placement.bounds}),nil)
    eq(#s.moves,0)
end)
test("review_uses_user_screen_even_after_agent_activation",function()
    local s=fixture();local a=s.app("md.obsidian",30);local w=s.window(8,a,s.b)
    local t=s.r.begin("automation","md.obsidian");eq(s.r.finish(t,8,30),nil) -- existing window, never adopted
    s.focus=w
    local p=assert(s.r.open("review","chrome",{userRequestedMain=true}));eq(p.placement.targetScreenUUID,"main")
end)
test("agent_test_or_preview_cannot_silently_authorize_a_main_screen_window",function()
    local s=fixture();local p,e=s.r.open("review","chrome",{purpose="show_test_to_user"})
    eq(p,nil);eq(e,"explicit_user_main_screen_request_required")
    eq(s.r.begin("review","local.codex.TestProbe"),nil);eq(#s.moves,0)
end)
test("registered_new_window_is_moved_once_without_focus",function()
    local s=fixture();local a=s.app("md.obsidian",30);local old=s.window(2,a,s.a)
    local token=s.r.begin("automation","md.obsidian");local w=s.window(3,a,s.a)
    eq(s.r.finish(token,3,30),true);eq(w:screen():getUUID(),"side");eq(old:screen():getUUID(),"main")
    eq(s.r.finish(token,3,30),nil);eq(#s.moves,1);eq(s.focusCalls,0)
end)
test("existing_personal_window_and_wrong_pid_are_refused",function()
    local s=fixture();local a=s.app("md.obsidian",30);s.window(2,a,s.a)
    local t=s.r.begin("review","md.obsidian",true);eq(s.r.finish(t,2,30),nil)
    t=s.r.begin("automation","md.obsidian");s.window(3,a,s.a);eq(s.r.finish(t,3,999),nil);eq(#s.moves,0)
end)
test("disconnection_and_pause_never_fall_back_to_main",function()
    local s=fixture();local t=s.r.begin("automation","md.obsidian");local a=s.app("md.obsidian",30);s.window(3,a,s.a)
    s.screens={s.a};eq(s.r.finish(t,3,30),nil);eq(#s.moves,0)
    eq(s.r.open("automation","chrome",{}),nil)
    s.screens={s.a,s.b};s.settings.codexComputerUseSafetySuspended=true
    eq(s.r.open("review","chrome",{}),nil)
end)
test("a_layout_change_during_open_requires_a_new_request",function()
    local s=fixture();local t=s.r.begin("automation","md.obsidian");local a=s.app("md.obsidian",30);s.window(3,a,s.b)
    s.layoutY=500;local ok,reason=s.r.finish(t,3,30)
    eq(ok,nil);eq(reason,"target_display_layout_changed");eq(#s.moves,0)
end)
test("status_reports_actual_pause_and_screen_state_without_opening_or_moving",function()
    local s=fixture();local status=s.r.status();eq(status.gatewayReady,true);eq(status.placement.targetDisplayID,1201)
    s.settings.codexComputerUseSafetySuspended=true;status=s.r.status()
    eq(status.safetySuspended,true);eq(status.assignmentEnabled,true);eq(status.gatewayReady,false)
    eq(status.reason,"auto_assignment_paused");eq(#s.moves,0);eq(#s.periodic,0)
end)
test("native_guard_requires_the_exact_owned_request_process_and_display",function()
    local s=fixture();local token=s.r.begin("automation","md.obsidian");local a=s.app("md.obsidian",30);local w=s.window(3,a,s.b)
    eq(s.r.finish(token,3,30),true);eq(s.r.guardNative(token,3,30).ok,true)
    eq(s.r.guardNative(token,3,999),nil);eq(s.r.guardNative("other",3,30),nil)
    w.display=s.a;local ok,reason=s.r.guardNative(token,3,30);eq(ok,nil);eq(reason,"owned_window_left_target")
    eq(#s.moves,0);eq(s.focusCalls,0)
end)
test("generic_app_registration_moves_only_the_new_window_and_allows_verified_focus",function()
    local s=fixture()
    local pending=assert(s.r.open("automation","app",{applicationSelector="Telegram"}))
    eq(pending.kind,"native_pending");eq(pending.completed,false)
    s.periodic[1].fn()
    eq(pending.createdByRequest,true)
    local result=s.r.results[pending.requestID]
    eq(result.ok,true);eq(result.bundleID,"ru.keepcoder.Telegram");eq(result.appPath,"/Applications/Telegram.app")
    eq(result.pid,70);eq(result.windowId,71);eq(result.connectionReady,true)
    eq(pending.connectionReady,true)
    eq(s.windows[71]:screen():getUUID(),"side");eq(#s.moves,1);eq(s.focusCalls,0)
    local app=s.hs.application.applicationForPID(70);s.front=app
    local authorized=s.r.guardNative(pending.requestID,71,70)
    eq(authorized.ok,true);eq(authorized.bundleID,"ru.keepcoder.Telegram")
    eq(authorized.appPath,"/Applications/Telegram.app");eq(authorized.connectionReady,true)
end)
test("existing_app_instances_are_never_reused_or_marked_connectable",function()
    local s=fixture();local personal=s.app("ru.keepcoder.Telegram",30,"/Applications/Telegram.app")
    local old=s.window(4,personal,s.a)
    local pending=assert(s.r.open("automation","app",{applicationSelector="Telegram"}))
    s.periodic[1].fn()
    local result=s.r.results[pending.requestID]
    eq(result.ok,true);eq(result.connectionReady,false);eq(result.connectionReason,"application_identity_not_unique")
    eq(pending.connectionReady,false)
    eq(old:screen():getUUID(),"main");eq(s.windows[71]:screen():getUUID(),"side")
    local ok,reason=s.r.guardNative(pending.requestID,71,70)
    eq(ok,nil);eq(reason,"application_identity_not_unique")
end)
test("generic_app_never_claims_a_reused_process_or_ambiguous_new_windows",function()
    local s=fixture();local personal=s.app("ru.keepcoder.Telegram",30,"/Applications/Telegram.app");s.window(4,personal,s.a)
    s.launchedPID=30
    local reused=assert(s.r.open("automation","app",{applicationSelector="Telegram"}))
    eq(s.r.results[reused.requestID].reason,"existing_application_reused");eq(#s.moves,0)
    eq(reused.createdByRequest,nil)

    s=fixture();s.extraNativeWindow=true
    local ambiguous=assert(s.r.open("automation","app",{applicationSelector="Telegram"}))
    s.periodic[1].fn()
    eq(s.r.results[ambiguous.requestID].reason,"new_application_window_ambiguous");eq(#s.moves,0)

    s=fixture();s.launchedBundleID="com.test.WrongApp"
    local wrongIdentity=assert(s.r.open("automation","app",{applicationSelector="Telegram"}))
    s.periodic[1].fn()
    eq(s.r.results[wrongIdentity.requestID].reason,"launched_application_identity_mismatch");eq(#s.moves,0)
end)
test("obsidian_foreground_permission_is_written_only_after_window_registration",function()
    local s=fixture();s.workerInstalled=true
    local p=assert(s.r.open("automation","obsidian",{}));local run=p.profile:match("^(.*)/profile$")
    local controlPath=run.."/control.json"
    local initial=s.hs.json.decode(s.files[controlPath]);eq(initial.foregroundAllowed,false)
    local app=s.app(p.workerBundleID,p.pid);s.window(9,app,s.b);p.backgroundReady=true
    s.periodic[1].fn()
    eq(s.r.results[p.requestID].ok,true)
    local control=s.hs.json.decode(s.files[controlPath]);eq(control.foregroundAllowed,true)
    s.settings.codexComputerUseSafetySuspended=true;s.periodic[1].fn()
    control=s.hs.json.decode(s.files[controlPath]);eq(control.enabled,false);eq(control.foregroundAllowed,false)
end)
test("an_unready_worker_is_terminated_on_pause_without_touching_any_other_process",function()
    local s=fixture();s.workerInstalled=true;local p=assert(s.r.open("automation","obsidian",{}))
    s.settings.codexComputerUseSafetySuspended=true;s.periodic[1].fn()
    eq(s.terminated,true);eq(s.r.results[p.requestID].reason,"auto_assignment_paused");eq(s.r.status().activeOwnedWorkers,0)
    eq(#s.moves,0);eq(s.focusCalls,0)
end)
test("a_ready_worker_is_paused_via_its_own_control_file_after_a_display_change",function()
    local s=fixture();s.workerInstalled=true;local p=assert(s.r.open("automation","obsidian",{}))
    local a=s.app(p.workerBundleID,60);s.window(9,a,s.b);p.backgroundReady=true
    s.periodic[1].fn();eq(s.r.results[p.requestID].ok,true);eq(s.periodic[1].timer.stopped,false)
    s.screens={s.a};s.periodic[1].fn()
    eq(s.r.results[p.requestID].ok,false);eq(s.r.results[p.requestID].reason,"target_screen_not_connected")
    eq(s.terminated,nil);eq(s.periodic[1].timer.stopped,true)
    local control;for _,event in ipairs(s.events)do if event.protocolVersion then control=event end end
    eq(control.enabled,false);eq(control.requestID,p.requestID);eq(#s.moves,0)
end)
test("ambiguous_new_windows_are_not_guessed",function()
    local s=fixture();local t=s.r.begin("automation","md.obsidian");local a=s.app("md.obsidian",30)
    s.window(2,a,s.a);s.window(3,a,s.a);eq(s.r.finish(t),nil);eq(#s.moves,0)
end)
test("human_input_requires_an_exact_window_id",function()
    local s=fixture();local t=s.r.begin("automation","md.obsidian");local a=s.app("md.obsidian",30);s.window(2,a,s.a)
    s.input({getProperty=function(_,key)return key==3 and 0 or 1 end});s.flush()
    eq(s.r.finish(t),nil);eq(#s.moves,0)
end)
test("obsidian_uses_background_worker_instead_of_demanding_foreground_permission",function()
    local s=fixture();local p,e=s.r.open("automation","obsidian",{})
    eq(p,nil);eq(e,"worker_not_installed")
    eq(s.r.obsidianWorkerBundleID,"local.codex.ObsidianWorkspace")
end)
test("each_obsidian_task_gets_a_distinct_app_path_for_exact_computer_use_binding",function()
    local s=fixture();s.workerInstalled=true
    local first=assert(s.r.open("automation","obsidian",{}))
    local second=assert(s.r.open("automation","obsidian",{}))
    assert(first.workerApp~=second.workerApp)
    assert(first.workerApp:find("/codex-obsidian-worker/tasks/",1,true))
    assert(second.workerApp:find("/codex-obsidian-worker/tasks/",1,true))
    eq(first.pid,60);eq(second.pid,61)
    eq(s.copyArgs[1],"-cR")
    eq(first.workerBundleID,second.workerBundleID)
    eq(s.taskArgs[3],second.workerApp.."/Contents/MacOS/Obsidian")
    assert(s.verifyArgs[1]=="--verify" and s.verifyArgs[#s.verifyArgs]==second.workerApp)
    local run=first.profile:match("^(.*)/profile$")
    local policy=s.files[run.."/protect-personal.sb"]
    assert(policy:find(first.workerApp.."/Contents/Frameworks/Obsidian Helper (GPU).app/Contents/MacOS/Obsidian Helper (GPU)",1,true))
end)
test("an_exact_verified_task_window_may_be_foregrounded",function()
    local s=fixture();s.workerInstalled=true
    local p=assert(s.r.open("automation","obsidian",{}));local app=s.app(p.workerBundleID,p.pid);local w=s.window(9,app,s.b)
    s.front=app;function app:focusedWindow()return w end
    local ok,reason=s.r.finish(p.requestID,9,p.pid)
    eq(ok,true);eq(reason.requestID,p.requestID);eq(s.r.owners[9]~=nil,true);eq(s.focusCalls,0)
    eq(s.r.guardNative(p.requestID,9,p.pid).ok,true)
end)
test("finder_uses_a_new_window_with_initial_bounds",function()
    local s=fixture();local a=s.app("com.apple.finder",51);local old=s.window(4,a,s.a)
    local ok,result=s.r.openFinderWindow("automation","/own/test")
    eq(ok,true);eq(result.windowId,55);eq(old:screen():getUUID(),"main");eq(result.movedAfterCreation,false)
    eq(result.targetDirectoryVerified,true)
    eq(result.backgroundWindowIndex,2)
    assert(s.script:find("make new Finder window",1,true));assert(not s.script:find("activate",1,true))
    assert(s.script:find("set index of newWindow to",1,true))
end)
test("finder_denial_does_not_reuse_or_move_a_personal_window",function()
    local s=fixture();s.denyFinder=true;local p=s.r.open("automation","finder",{directory="/own/test"})
    eq(p,nil);eq(#s.moves,0)
end)
local passed=0;for _,r in ipairs(results)do if r.passed then passed=passed+1 end end
return{passed=passed,total=#results,cases=results}
