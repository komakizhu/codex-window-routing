-- Explicit, isolated live acceptance. No installed loader/module is replaced.
-- Pass absolute source/artifact directories. Only this run's task may be closed.
local source, artifacts, runtimeRoot, injectedDisplayID = ...
assert(type(source)=="string" and source:sub(1,1)=="/")
assert(type(artifacts)=="string" and artifacts:sub(1,1)=="/")
assert(type(runtimeRoot)=="string" and runtimeRoot:match("^/private/tmp/cuw%-"))
assert(hs.settings.get("codexComputerUseSafetySuspended")~=true,"safety is suspended")
assert(hs._codexComputerUseSidecar and hs._codexComputerUseSidecar.enabled,"assignment is paused")
local copiedSidecar={placement=hs._codexComputerUseSidecar.placement}
setmetatable(copiedSidecar,{__index=function(_,key)
    if key=="enabled" then return hs._codexComputerUseSidecar.enabled end
end})
local isolated=setmetatable({configdir=artifacts,_codexExternalWindowRouter=false,
    _codexWindowGateway=false,_codexComputerUseSidecar=copiedSidecar},{__index=hs})
-- Fault injection changes only the plan seen by this test, never real displays.
if injectedDisplayID then
    assert(type(injectedDisplayID)=="number")
    isolated.screen={allScreens=function()
        local out={}
        for _,real in ipairs(hs.screen.allScreens()) do
            out[#out+1]=setmetatable({id=function()return injectedDisplayID end},{__index=function(_,key)
                return function(_,...)return real[key](real,...)end
            end})
        end
        return out
    end}
end
local env=setmetatable({hs=isolated},{__index=_G})
local gateway=assert(loadfile(source.."/hammerspoon/window_gateway.lua","t",env))()
local state={gateway=gateway,events={},startedAt=hs.timer.secondsSinceEpoch()}
local before=hs.application.frontmostApplication()
state.beforePID=before and before:pid()
state.watcher=hs.application.watcher.new(function(_,event,app)
    if event==hs.application.watcher.activated then
        state.events[#state.events+1]={pid=app and app:pid(),at=hs.timer.secondsSinceEpoch()}
    end
end):start()
local p,reason=gateway.open("automation","obsidian",{runtimeRoot=runtimeRoot,
    protectedDirectories={"/Users/example/Documents/Obsidian/ExampleUser"}})
if not p then state.watcher:stop();gateway.stop();error(tostring(reason)) end
state.pending=p
function state.snapshot()
    local workerRunning=p.task and p.task:isRunning() or p.copyTask and p.copyTask:isRunning() or false
    local a=p.task and p.task:isRunning() and p.backgroundReady and hs.application.applicationForPID(p.pid) or nil
    local windows={}
    if a then for _,w in ipairs(a:allWindows()) do
        windows[#windows+1]={id=w:id(),role=w:role(),subrole=w:subrole(),visible=w:isVisible(),screenUUID=w:screen() and w:screen():getUUID()}
    end end
    local front=hs.application.frontmostApplication()
    return {pid=p.pid,workerApp=p.workerApp,workerBundleID=p.workerBundleID,requestID=p.requestID,vault=p.vault,
        result=gateway.results[p.requestID],events=p.backgroundEvents,activations=state.events,
        beforePID=state.beforePID,afterPID=front and front:pid(),windows=windows,
        injectedDisplayID=injectedDisplayID,running=workerRunning,copying=p.copyTask and p.copyTask:isRunning() or false,
        userInputEvents=gateway.physicalSequence,
        elapsed=hs.timer.secondsSinceEpoch()-state.startedAt}
end
function state.pause()
    local file=p.profile:match("^(.*)/profile$").."/control.json"
    local f=assert(io.open(file..".tmp","w"))
    f:write(hs.json.encode({protocolVersion=1,requestID=p.requestID,enabled=false}));f:close()
    assert(os.rename(file..".tmp",file))
end
function state.finish()
    assert((not p.pid or p.task and p.task:pid()==p.pid)
        and p.workerApp:find(artifacts.."/codex-obsidian-worker/",1,true)==1)
    if p.copyTask and p.copyTask:isRunning() then p.copyTask:terminate() end
    if p.task and p.task:isRunning() then p.task:terminate() end
    state.watcher:stop();gateway.stop()
    if state.deadline then state.deadline:stop() end
    return state.snapshot()
end
-- Self-cleanup if the caller is interrupted. Never touches another run's PID.
state.deadline=hs.timer.doAfter(300,function()state.finish()end)
return state
