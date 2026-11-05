-- Isolated typed bridge tests: no real app, process, window, or settings calls.
local api=assert(...)
local function eq(a,b)assert(a==b,tostring(a).." ~= "..tostring(b))end
local function fixture()
    local s={opened=0,terminated=0,closed=0,running=true}
    local g={tickets={},results={},pending={},owners={}}
    g.status=function()return{gatewayReady=true,activeOwnedWorkers=1}end
    g.open=function(intent,app,options)
        s.opened=s.opened+1;s.intent=intent;s.options=options
        if app=="finder" then return{ok=true,requestID="finder",pid=20,windowId=30,targetScreenUUID="side",targetDirectoryVerified=true}end
        if app=="app" then return{ok=true,kind="native_pending",requestID="native-ticket",completed=false}end
        return{kind="native_pending",requestID="worker",pid=40,workerApp="/safe/codex-obsidian-worker/Task.app",task={}}
    end
    local task={pid=function()return 40 end,isRunning=function()return s.running end,
        terminate=function()s.running=false;s.terminated=s.terminated+1 end}
    g.pending.worker={pid=40,task=task,workerApp="/safe/codex-obsidian-worker/Task.app"}
    g.results.worker={ok=true,windowId=50,backgroundBootstrapInstalled=true}
    g.owners[50]={requestID="worker",pid=40}
    g.results.native={ok=true,requestID="native",windowId=70,pid=71,connectionReady=true}
    g.owners[70]={requestID="native",pid=71,bundleID="ru.keepcoder.Telegram",
        appPath="/Applications/Telegram.app",displayName="Telegram",connectionMode="unique_application",connectionReady=true}
    g.guardNative=function(token,id,pid)
        if token=="worker" and id==50 and pid==40 and s.running then return{ok=true,pid=pid,windowId=id,requestID=token}end
        if token=="native" and id==70 and pid==71 and s.running then return{ok=true,pid=pid,windowId=id,requestID=token}end
        if token=="second" and id==51 and pid==41 and s.secondRunning then return{ok=true,pid=pid,windowId=id,requestID=token}end
        return nil,"not_owned"
    end
    g.closeOwnWindow=function(id,pid)
        if id==50 and pid==40 then s.closed=s.closed+1;return true end
        return nil,"not_owned"
    end
    g.checkBrowserRequest=function(token,connection,plan)
        if token=="browser" and connection=="connection" and plan.targetScreenUUID=="side" then return{ok=true,requestID=token}end
        return nil,"browser_connection_mismatch"
    end
    local fake={configdir="/safe",_codexWindowGateway=g,_codexComputerUseSidecar={enabled=true},settings={get=function()return false end}}
    function s.call(request)return assert(loadfile(api,"t",setmetatable({hs=fake},{__index=_G})))(request)end
    s.g=g;s.hs=fake;return s
end
local results={}
local function test(name,fn)local ok,err=pcall(fn);results[#results+1]={name=name,passed=ok,error=not ok and tostring(err)or nil}end
test("status_is_read_only_and_works_with_a_deliberately_unloaded_gateway",function()
    local s=fixture();eq(s.call({action="status"}).gateway.gatewayReady,true);eq(s.opened,0)
    s.hs._codexWindowGateway=nil;eq(s.call({action="status"}).gateway.gatewayReady,false);eq(s.opened,0)
end)
test("agent_open_never_accepts_a_main_screen_intent_or_an_unknown_application",function()
    local s=fixture();eq(s.call({action="open",application="finder",intent="review",directory="/task"}).ok,false)
    eq(s.call({action="open",application="unknown"}).ok,false);eq(s.opened,0)
end)
test("finder_returns_exact_new_window_metadata_and_browser_requires_connection_proof",function()
    local s=fixture();local out=s.call({action="open",application="finder",directory="/task"})
    eq(out.windowId,30);eq(out.pid,20);eq(out.targetDirectoryVerified,true);eq(s.intent,"automation")
    eq(s.call({action="open",application="chrome"}).ok,false);eq(s.opened,1)
    eq(s.call({action="open",application="chrome",browserBaselineIDs={10},extensionInstanceId="connection"}).ok,true)
    eq(s.options.browserExtensionInstanceId,"connection")
end)
test("generic_app_open_requires_a_selector_and_connection_uses_exact_owned_window_identity",function()
    local s=fixture()
    eq(s.call({action="open",application="app"}).reason,"application_selector_required")
    local opened=s.call({action="open",application="app",applicationSelector="Telegram"})
    eq(opened.ok,true);eq(opened.kind,"native_pending");eq(s.options.applicationSelector,"Telegram")
    s.g.owners[72]={requestID="other",pid=72,bundleID="com.example.Telegram",
        appPath="/Applications/OtherTelegram.app",displayName="Telegram",connectionMode="unique_application",connectionReady=true}
    s.g.results.other={ok=true,requestID="other",connectionReady=true}
    eq(s.call({action="authorize-app",identity="Telegram"}).reason,"not_an_active_registered_task_window")
    eq(s.call({action="authorize-app",identity="telegram"}).reason,"not_an_active_registered_task_window")
    eq(s.call({action="authorize-app",identity="Telegram.app"}).reason,"not_an_active_registered_task_window")
    eq(s.call({action="authorize-app",identity="/Applications/Telegram.app"}).ok,true)
    eq(s.call({action="authorize-app",identity="ru.keepcoder.Telegram"}).ok,true)
    eq(s.call({action="authorize-app",identity="ru.keepcoder.telegram"}).reason,"not_an_active_registered_task_window")
    eq(s.call({action="authorize-app",requestID="native",pid=71,windowId=70}).ok,true)
    eq(s.call({action="authorize-app",identity="Unknown"}).reason,"not_an_active_registered_task_window")
    s.g.owners[72]={requestID="second",pid=72,bundleID="ru.keepcoder.Telegram",
        appPath="/Applications/Telegram.app",displayName="Telegram",connectionMode="unique_application",connectionReady=true}
    s.g.results.second={ok=true,requestID="second",connectionReady=true}
    eq(s.call({action="authorize-app",identity="ru.keepcoder.Telegram"}).reason,"application_identity_ambiguous")
end)
test("native_request_exposes_connection_readiness_at_the_top_level",function()
    local s=fixture()
    s.g.pending.native={kind="native_pending",requestID="native",completed=true,appPath="/Applications/Task.app",
        bundleID="com.test.Task",pid=71,windowId=70,targetScreenUUID="side"}
    s.g.results.native={ok=true,requestID="native",appPath="/Applications/Task.app",bundleID="com.test.Task",
        pid=71,windowId=70,targetScreenUUID="side",connectionReady=true}
    local out=s.call({action="request",requestID="native"})
    eq(out.result.connectionReady,true);eq(out.connectionReady,true);eq(out.requestID,"native")
end)
test("app_authorization_requires_one_live_and_accepted_exact_worker",function()
    local s=fixture();local request={action="authorize-app",appPath="/safe/codex-obsidian-worker/Task.app"}
    eq(s.call(request).ok,true);s.running=false;eq(s.call(request).ok,false);s.running=true
    s.g.pending.second=s.g.pending.worker;s.g.results.second=s.g.results.worker
    eq(s.call(request).reason,"worker_app_ambiguous");eq(s.opened,0)
end)
test("parallel_workers_are_authorized_by_their_distinct_app_paths",function()
    local s=fixture();s.secondRunning=true
    local task={pid=function()return 41 end,isRunning=function()return s.secondRunning end}
    s.g.pending.second={pid=41,task=task,workerApp="/safe/codex-obsidian-worker/Task-2.app"}
    s.g.results.second={ok=true,windowId=51,backgroundBootstrapInstalled=true}
    s.g.owners[51]={requestID="second",pid=41}
    eq(s.call({action="authorize-app",appPath="/safe/codex-obsidian-worker/Task.app"}).requestID,"worker")
    eq(s.call({action="authorize-app",appPath="/safe/codex-obsidian-worker/Task-2.app"}).requestID,"second")
end)
test("browser_authorization_keeps_the_original_ticket_and_connection",function()
    local s=fixture();eq(s.call({action="authorize-browser",requestID="browser",extensionInstanceId="connection",placement={targetScreenUUID="side"}}).ok,true)
    eq(s.call({action="authorize-browser",requestID="browser",extensionInstanceId="other",placement={targetScreenUUID="side"}}).ok,false)
end)
test("cleanup_never_accepts_another_request_or_process",function()
    local s=fixture()
    eq(s.call({action="close-native",requestID="another",pid=40,windowId=50}).ok,false)
    eq(s.call({action="close-native",requestID="worker",pid=41,windowId=50}).ok,false);eq(s.closed,0)
    eq(s.call({action="close-native",requestID="worker",pid=40,windowId=50}).ok,true);eq(s.closed,1)
    eq(s.call({action="stop-worker",requestID="worker",pid=41}).ok,false);eq(s.terminated,0)
    eq(s.call({action="stop-worker",requestID="worker",pid=40}).ok,true);eq(s.terminated,1)
end)
test("live_acceptance_entry_parses_without_executing_or_opening_a_window",function()
    local source=api:match("^(.*)/routing/window_api.lua$")
    assert(source,"source root should be derivable from the API test path")
    local chunk,reason=loadfile(source.."/hammerspoon/test/window_routing_acceptance.lua")
    assert(chunk,reason)
end)
local passed=0;for _,r in ipairs(results)do if r.passed then passed=passed+1 end end
return{passed=passed,total=#results,cases=results}
