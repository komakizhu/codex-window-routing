-- Typed CLI bridge. It never evaluates caller-supplied Lua or infers ownership.
local request, selectedGateway = ...
assert(type(request)=="table","request object required")
local g=selectedGateway or hs._codexWindowGateway
local function fail(reason) return {ok=false,reason=reason} end
local function integer(value) return type(value)=="number" and value%1==0 and value>0 end
local function text(value) return type(value)=="string" and value~="" and not value:find("[%z\r\n]") end
local function pendingRecord(p)
    return {ok=true,kind=p.kind,requestID=p.requestID,pid=p.pid,workerApp=p.workerApp,
        workerBundleID=p.workerBundleID,appPath=p.appPath,bundleID=p.bundleID,displayName=p.displayName,
        profile=p.profile,vault=p.vault,placement=p.placement,
        copying=p.copyTask and p.copyTask:isRunning() or false,
        windowId=p.windowId,targetScreenUUID=p.targetScreenUUID,intent=p.intent,
        targetDirectoryVerified=p.targetDirectoryVerified,movedAfterCreation=p.movedAfterCreation,
        foregroundChanged=p.foregroundChanged,backgroundWindowIndex=p.backgroundWindowIndex,
        extensionInstanceId=p.extensionInstanceId,connectionReady=p.connectionReady,
        connectionReason=p.connectionReason,
        completed=p.completed}
end
if request.action=="status" then
    local sidecar=hs._codexComputerUseSidecar
    local state={ok=true,gatewayLoaded=g~=nil,safetySuspended=hs.settings.get("codexComputerUseSafetySuspended")==true,
        assignmentEnabled=sidecar and sidecar.enabled==true or false}
    if g and g.status then state.gateway=g.status()
    elseif g and g.placementForIntent then
        local plan,reason=g.placementForIntent("automation")
        state.gateway={gatewayReady=plan~=nil,reason=reason,placement=plan,legacyRuntime=true}
    else state.gateway={gatewayReady=false,reason="gateway_not_loaded"} end
    return state
end
if not g then return fail("gateway_not_loaded") end
if request.action=="authorize-app" then
    if text(request.appPath) then
        local matches={}
        for token,p in pairs(g.pending or {}) do
            local result=g.results[token]
            if p.workerApp==request.appPath and p.task and p.task:isRunning()
                and p.pid==p.task:pid() and result and result.ok and result.backgroundBootstrapInstalled then
                matches[#matches+1]={token=token,p=p,result=result}
            end
        end
        if #matches~=1 then return fail(#matches>1 and "worker_app_ambiguous" or "not_an_active_registered_worker") end
        if not g.guardNative then return fail("gateway_update_required") end
        local match=matches[1]
        local result,reason=g.guardNative(match.token,match.result.windowId,match.p.pid)
        return result or fail(reason)
    end
    if text(request.requestID) and integer(request.pid) and integer(request.windowId) then
        local owner=g.owners[request.windowId]
        if not owner or owner.requestID~=request.requestID or owner.pid~=request.pid then return fail("not_owned") end
        local result,reason=g.guardNative(request.requestID,request.windowId,request.pid)
        return result or fail(reason)
    end
    if not text(request.identity) then return fail("registered_application_identity_required") end
    local matches={}
    for id,owner in pairs(g.owners or {}) do
        local result=g.results[owner.requestID]
        local matchesIdentity=request.identity==owner.appPath
            or type(owner.bundleID)=="string" and request.identity==owner.bundleID
        if owner.connectionMode=="unique_application" and matchesIdentity and result
            and result.ok and result.connectionReady then
            matches[#matches+1]={id=id,owner=owner,result=result}
        end
    end
    if #matches~=1 then return fail(#matches>1 and "application_identity_ambiguous" or "not_an_active_registered_task_window") end
    if not g.guardNative then return fail("gateway_update_required") end
    local match=matches[1]
    local result,reason=g.guardNative(match.owner.requestID,match.id,match.owner.pid)
    return result or fail(reason)
end
if request.action=="open" then
    if request.intent and request.intent~="automation" then return fail("agent_cli_only_allows_automation") end
    if request.application~="chrome" and request.application~="finder" and request.application~="obsidian"
        and request.application~="app" then
        return fail("unsupported_application")
    end
    local options={}
    if request.application=="app" then
        if not text(request.applicationSelector) then return fail("application_selector_required") end
        options.applicationSelector=request.applicationSelector
    elseif request.application=="finder" then
        if not text(request.directory) or request.directory:sub(1,1)~="/" then return fail("absolute_directory_required") end
        options.directory=request.directory
    elseif request.application=="chrome" then
        if type(request.browserBaselineIDs)~="table" or not text(request.extensionInstanceId) then
            return fail("browser_connection_and_baseline_required")
        end
        for _,id in ipairs(request.browserBaselineIDs) do if not integer(id) then return fail("invalid_browser_baseline") end end
        options.browserBaselineIDs=request.browserBaselineIDs
        options.browserExtensionInstanceId=request.extensionInstanceId
    else
        options.protectedDirectories=request.protectedDirectories or {}
        if type(options.protectedDirectories)~="table" then return fail("invalid_protected_directories") end
        for _,path in ipairs(options.protectedDirectories) do
            if not text(path) or path:sub(1,1)~="/" then return fail("invalid_protected_directory") end
        end
    end
    local result,reason=g.open("automation",request.application,options)
    if not result then return fail(type(reason)=="table" and reason.reason or reason) end
    return pendingRecord(result)
end
if not text(request.requestID) then return fail("request_id_required") end
if request.action=="authorize-browser" then
    if not g.checkBrowserRequest then return fail("gateway_update_required") end
    local result,reason=g.checkBrowserRequest(request.requestID,request.extensionInstanceId,request.placement)
    return result or fail(reason)
end
if request.action=="request" then
    local p=g.pending and g.pending[request.requestID]
    local result=g.results[request.requestID]
    local ticket=g.tickets[request.requestID]
    if not p and not result and not ticket then return fail("unknown_request") end
    local out=p and pendingRecord(p) or {ok=true,requestID=request.requestID}
    if result then
        out.result=result
        out.ok=result.ok==true
        for _,key in ipairs({"appPath","bundleID","displayName","pid","windowId","targetScreenUUID",
            "connectionReady","connectionReason","reason"}) do
            if result[key]~=nil then out[key]=result[key] end
        end
    end
    if p then out.running=p.task and p.task:isRunning() or false end
    if ticket then out.placement=ticket.plan;out.kind=ticket.bundle=="com.google.Chrome" and "browser" or out.kind end
    return out
end
if request.action=="finish-browser" then
    if type(request.proof)~="table" then return fail("browser_proof_required") end
    local ok,result=g.finishBrowser(request.requestID,request.proof)
    return ok and result or fail(result)
end
if not integer(request.pid) then return fail("exact_pid_required") end
if request.action=="stop-worker" then
    local p=g.pending and g.pending[request.requestID]
    if not p or not p.task or p.pid~=request.pid or p.task:pid()~=request.pid
        or type(p.workerApp)~="string"
        or p.workerApp:find(hs.configdir.."/codex-obsidian-worker/",1,true)~=1 then return fail("not_owned_worker") end
    if p.task:isRunning() then p.task:terminate() end
    return {ok=true,requestID=request.requestID,pid=request.pid,stopRequested=true}
end
if not integer(request.windowId) then return fail("exact_window_id_required") end
if request.action=="check-native" then
    if not g.guardNative then return fail("gateway_update_required") end
    local result,reason=g.guardNative(request.requestID,request.windowId,request.pid)
    return result or fail(reason)
end
if request.action=="close-native" then
    local owner=g.owners[request.windowId]
    if not owner or owner.requestID~=request.requestID or owner.pid~=request.pid then return fail("not_owned") end
    local ok,reason=g.closeOwnWindow(request.windowId,request.pid)
    return ok and {ok=true,requestID=request.requestID,windowId=request.windowId,pid=request.pid} or fail(reason)
end
return fail("unsupported_action")
