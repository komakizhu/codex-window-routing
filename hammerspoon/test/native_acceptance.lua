-- Explicitly invoked real-app checks. Loading prepares no GUI or user data.
local a = { records = {} }
local ROOT = "/Users/example/Documents/ChatGPT/修复computer use抢鼠标/hammerspoon/test"
local ID = "c0de5c0de5c0de50"
local function save()
    if not a.root then return end
    local f = assert(io.open(a.root .. "/results.json", "w"))
    f:write(assert(hs.json.encode(a.records, true))); f:close()
end
local function record(event, details)
    local app = hs.application.frontmostApplication()
    local w = app and app:focusedWindow()
    local item = { event = event, at = hs.timer.secondsSinceEpoch(),
        frontBundleID = app and app:bundleID(), focusedWindowId = w and w:id(),
        physicalSequence = hs._codexExternalWindowRouter.physicalSequence, details = details }
    a.records[#a.records + 1] = item; save()
    return item
end
local function write(path, value)
    local f = assert(io.open(path, "w")); f:write(value); f:close()
end
function a.prepare()
    local plan = hs._codexComputerUseSidecar.newWindowPlacement()
    assert(plan.bounds and not plan.reason, "No usable side screen")
    a.root = ROOT .. "/.native-runtime-" .. tostring(math.floor(hs.timer.secondsSinceEpoch()))
    assert(hs.fs.mkdir(a.root));a.profile = a.root .. "/profile";a.vault = a.root .. "/vault"
    assert(hs.fs.mkdir(a.profile));assert(hs.fs.mkdir(a.vault))
    write(a.vault .. "/副屏测试.md", "# 副屏测试\n\n这是独立测试库，不含个人资料。\n")
    write(a.profile .. "/obsidian.json", assert(hs.json.encode({vaults={
        [ID]={path=a.vault,ts=math.floor(hs.timer.secondsSinceEpoch()*1000),open=true}}})))
    local b=plan.bounds
    -- Installed Obsidian reads per-vault geometry before constructing its
    -- BrowserWindow. This file belongs only to the new disposable profile.
    write(a.profile .. "/" .. ID .. ".json", assert(hs.json.encode({x=b.left,y=b.top,
        width=b.width,height=b.height,isMaximized=false})))
    record("prepared", {targetScreenUUID=plan.targetScreenUUID})
    return {root=a.root,profile=a.profile,vault=a.vault}
end
function a.startAudit()
    a.watcher=hs.application.watcher.new(function(_,event,app)
        if event==hs.application.watcher.activated then
            record("application_activated",{bundleID=app and app:bundleID()})
        end
    end):start()
end
function a.launchObsidian(mode)
    assert(a.root and not a.task,"prepare a fresh test profile first")
    a.launchMode=mode or "background"
    assert(a.launchMode=="background" or a.launchMode=="direct", "unknown launch mode")
    local router=hs._codexExternalWindowRouter
    local token,plan=router.begin("automation","md.obsidian")
    assert(token,plan)
    local b=plan.bounds
    write(a.profile .. "/" .. ID .. ".json", assert(hs.json.encode({x=b.left,y=b.top,
        width=b.width,height=b.height,isMaximized=false})))
    record("obsidian_before_launch",{mode=a.launchMode})
    local executable="/Applications/Obsidian.app/Contents/MacOS/Obsidian"
    local launchPath=a.launchMode=="background" and "/usr/bin/open" or executable
    local args={"--user-data-dir="..a.profile,a.vault}
    if a.launchMode=="background" then
        args={"-g","-n","-a","/Applications/Obsidian.app","--args",args[1],args[2]}
    end
    a.task=assert(hs.task.new(launchPath,function(code)
        record(a.launchMode=="background" and "obsidian_launcher_exit" or "obsidian_process_exit",{exitCode=code})
    end,function() return true end,args))
    assert(a.task:start())
    if a.launchMode=="direct" then a.pid=a.task:pid() end
    local function identifyOwnProcess()
        if a.pid or a.probing then return end
        a.probing=true
        a.pidProbe=hs.task.new("/bin/ps",function(_,output)
            a.probing=false
            local matches={}
            for line in output:gmatch("[^\n]+") do
                local pid,command=line:match("^%s*(%d+)%s+(.+)$")
                if command and command:sub(1,#executable+1)==executable.." "
                    and command:find("--user-data-dir="..a.profile,1,true) then
                    matches[#matches+1]=tonumber(pid)
                end
            end
            if #matches==1 then
                a.pid=matches[1];record("identified_own_obsidian_process",{pid=a.pid})
            elseif #matches>1 then
                a.timer:stop();record("obsidian_check_failed",{reason="ambiguous_profile_process"})
            end
        end,{"-ww","-axo","pid,command"})
        assert(a.pidProbe:start())
    end
    local attempts=0
    a.timer=hs.timer.doEvery(0.1,function()
        attempts=attempts+1
        if not a.pid and attempts%5==1 then identifyOwnProcess() end
        local app=a.pid and hs.application.applicationForPID(a.pid)
        if app then a.ownApplication=app end
        local windows={}
        if app and app:bundleID()=="md.obsidian" then
            for _,w in ipairs(app:allWindows()) do
                if w:role()=="AXWindow" and w:subrole()=="AXStandardWindow" then windows[#windows+1]=w end
            end
        end
        if #windows>1 or attempts>=300 then
            a.timer:stop();record("obsidian_check_failed",{reason=#windows>1 and "multiple_windows" or "timeout"})
        elseif #windows==1 then
            a.timer:stop()
            local w=windows[1];local first=w:screen() and w:screen():getUUID()
            local ok,detail=router.finish(token,w:id());local f=w:frame()
            a.obsidianResult={pid=a.pid,windowId=w:id(),routed=ok==true,detail=detail,
                firstObservedScreenUUID=first,targetScreenUUID=plan.targetScreenUUID,
                finalScreenUUID=w:screen() and w:screen():getUUID(),
                frame={x=f.x,y=f.y,w=f.w,h=f.h}}
            record("obsidian_routing_result",a.obsidianResult)
        end
    end)
    return {pid=a.pid,token=token,mode=a.launchMode}
end
function a.openFinder()
    assert(a.root and not (a.finderResult and a.finderResult.windowId),"close the prior test Finder window first")
    record("finder_before_create")
    local ok,result=hs._codexExternalWindowRouter.openFinderWindow("automation",a.vault)
    a.finderResult=result
    record("finder_result",{ok=ok==true,result=result})
    return {ok=ok==true,result=result}
end
function a.closeOwnWindows()
    if a.timer then a.timer:stop() end
    if a.launchMode=="background" then
        if a.ownApplication and a.ownApplication:isRunning() then a.ownApplication:kill() end
    elseif a.task and a.task:isRunning() then a.task:terminate() end
    local id=a.finderResult and a.finderResult.windowId
    local owner=id and hs._codexExternalWindowRouter.owners[id]
    local w=id and hs.window.get(id)
    if w and owner and owner.intent=="automation" and owner.pid==w:application():pid()
        and w:application():bundleID()=="com.apple.finder" then w:close() end
    record("cleaned_up_own_windows")
    if a.watcher then a.watcher:stop() end
end
return a
