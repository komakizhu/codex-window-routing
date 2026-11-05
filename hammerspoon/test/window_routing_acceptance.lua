-- Opt-in live tests. The installed gateway, settings and old windows are untouched.
local source,artifacts,runtimeRoot=...
assert(type(source)=="string" and source:sub(1,1)=="/")
assert(type(artifacts)=="string" and artifacts:sub(1,1)=="/")
assert(type(runtimeRoot)=="string" and runtimeRoot:match("^/private/tmp/cuw%-"))
local testHome=runtimeRoot.."/home"
local nativeLauncher=testHome.."/.codex/window-routing/current/bin/native-app-launcher"
assert(hs.fs.attributes(nativeLauncher,"mode")=="file","candidate native app launcher is missing")
assert(hs.settings.get("codexComputerUseSafetySuspended")~=true,"safety is suspended")
assert(hs._codexComputerUseSidecar and hs._codexComputerUseSidecar.enabled,"assignment is paused")
assert(not hs._codexWindowRoutingAcceptance,"another routing acceptance is active")
local copiedSidecar={placement=hs._codexComputerUseSidecar.placement}
setmetatable(copiedSidecar,{__index=function(_,key)
    if key=="enabled" then return hs._codexComputerUseSidecar.enabled end
end})
local isolated=setmetatable({configdir=artifacts,_codexExternalWindowRouter=false,
    _codexWindowGateway=false,_codexComputerUseSidecar=copiedSidecar},{__index=hs})
local isolatedOS=setmetatable({getenv=function(name)
    if name=="HOME" then return testHome end
    return os.getenv(name)
end,rename=os.rename},{__index=os})
local env=setmetatable({hs=isolated,os=isolatedOS},{__index=_G})
local gateway=assert(loadfile(source.."/hammerspoon/window_gateway.lua","t",env))()
local originalOpen=gateway.open
gateway.open=function(intent,application,options)
    if application=="obsidian" then options.runtimeRoot=runtimeRoot end
    return originalOpen(intent,application,options)
end
local state={gateway=gateway,events={},startedAt=hs.timer.secondsSinceEpoch()}
local function oldWindows()
    local out={}
    local bundles={['com.google.Chrome']=true,['com.apple.finder']=true,['md.obsidian']=true,
        ['local.codex.ObsidianWorkspace']=true}
    for _,a in ipairs(hs.application.runningApplications()) do
        if bundles[a:bundleID()] then for _,w in ipairs(a:allWindows()) do
            if w:isStandard() then
                local f=w:frame()
                out[tostring(a:pid())..":"..w:id()]={pid=a:pid(),id=w:id(),frame={x=f.x,y=f.y,w=f.w,h=f.h},
                    screenUUID=w:screen() and w:screen():getUUID()}
            end
        end end
    end
    return out
end
state.before=oldWindows()
local before=hs.application.frontmostApplication()
state.beforePID=before and before:pid()
state.watcher=hs.application.watcher.new(function(_,event,app)
    if event==hs.application.watcher.activated then
        state.events[#state.events+1]={pid=app and app:pid(),at=hs.timer.secondsSinceEpoch()}
    end
end):start()
function state.call(request)
    return assert(loadfile(source.."/routing/window_api.lua","t",env))(request,gateway)
end
function state.snapshot()
    local current=oldWindows()
    local unchanged,changed,missing=0,{},{}
    for key,b in pairs(state.before) do
        local a=current[key]
        if not a then missing[#missing+1]=b
        elseif a.screenUUID==b.screenUUID and a.frame.x==b.frame.x and a.frame.y==b.frame.y
            and a.frame.w==b.frame.w and a.frame.h==b.frame.h then unchanged=unchanged+1
        else changed[#changed+1]={before=b,after=a} end
    end
    local front=hs.application.frontmostApplication()
    local results={}
    for token,result in pairs(gateway.results) do results[token]=result end
    return {before=state.before,unchanged=unchanged,changed=changed,missing=missing,results=results,
        activations=state.events,beforePID=state.beforePID,afterPID=front and front:pid(),
        elapsed=hs.timer.secondsSinceEpoch()-state.startedAt}
end
function state.finish()
    for id,owner in pairs(gateway.owners) do gateway.closeOwnWindow(id,owner.pid) end
    for _,p in pairs(gateway.pending) do
        if p.kind=="native_pending" and p.createdByRequest==true and p.task
            and p.task:isRunning() and p.pid==p.task:pid()
            and p.task:bundleID()==p.bundleID and p.task:path()==p.appPath then p.task:kill() end
        if p.task and p.task:isRunning() and p.pid==p.task:pid()
            and type(p.workerApp)=="string"
            and p.workerApp:find(artifacts.."/codex-obsidian-worker/",1,true)==1 then p.task:terminate() end
    end
    state.watcher:stop();gateway.stop()
    if state.deadline then state.deadline:stop() end
    return state.snapshot()
end
state.deadline=hs.timer.doAfter(300,function()state.finish()end)
return state
