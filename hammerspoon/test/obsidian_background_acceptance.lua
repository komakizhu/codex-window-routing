-- Explicit test only: no personal windows, no input injection, no focus restore.
-- Pass an existing bounded audit and the exact current gateway-owned worker.
local audit, current = ...
local gateway = assert(hs._codexWindowGateway)
local batch = { results = {}, done = false }
local function summarize(r)
    return { label=r.label,first=r.first,last=r.last,
        focusChangedSamples=r.focusChangedSamples,inputChangedSamples=r.inputChangedSamples,
        activations=r.activations,details=r.details }
end
local function stopOwned(p, continuation)
    assert(p and p.task:pid()==p.pid and p.workerBundleID==gateway.obsidianWorkerBundleID)
    audit.start("final-build-shutdown-"..tostring(#batch.results))
    p.task:terminate()
    local tries=0;local timer
    timer=hs.timer.doEvery(0.1,function()
        tries=tries+1
        if not p.task:isRunning() or tries>=50 then
            timer:stop()
            local r=audit.finish({pid=p.pid,stopped=not p.task:isRunning()})
            batch.results[#batch.results+1]=summarize(r)
            if p.task:isRunning() then batch.done=true;batch.error="owned_worker_did_not_exit";return end
            continuation()
        end
    end)
end
local function start(index)
    audit.start("final-build-startup-"..index)
    local p,err=gateway.open("automation","obsidian",{
        protectedDirectories={"/Users/example/Documents/Obsidian/ExampleUser"},
    })
    if not p then audit.finish({error=err});batch.done=true;batch.error=err;return end
    hs._codexObsidianBackgroundJob=p
    local timer;local afterResult=false
    timer=hs.timer.doEvery(0.1,function()
        local result=gateway.results[p.requestID]
        if result and not afterResult then
            afterResult=true;timer:stop()
            hs.timer.doAfter(1,function()
                local r=audit.finish({result=result,profile=p.profile,vault=p.vault,events=p.backgroundEvents})
                batch.results[#batch.results+1]=summarize(r)
                if not result.ok then batch.done=true;batch.error=result.reason;return end
                if index<3 then stopOwned(p,function()start(index+1)end)
                else batch.done=true end
            end)
        end
    end)
end
stopOwned(current,function()start(2)end)
return batch
