-- One explicit opening gateway. No Dock/menu inference and no personal-window
-- focus restoration. Only windows created after their request can be managed.
local previous = hs._codexExternalWindowRouter
if previous and previous.stop then previous.stop() end
local g = { tickets = {}, owners = {}, results = {}, pending = {}, sequence = 0, physicalSequence = 0 }
if previous and previous == hs._codexWindowGateway then
    g.owners, g.results, g.browserOwners = previous.owners, previous.results, previous.browserOwners
    g.sequence, g.physicalSequence = previous.sequence, previous.physicalSequence
    g.pending = previous.pending or {}
end
g.browserOwners = g.browserOwners or {}
local bundles = { chrome = "com.google.Chrome", finder = "com.apple.finder", obsidian = "local.codex.ObsidianWorkspace" }
g.obsidianWorkerBundleID = bundles.obsidian
local function now() return hs.timer.secondsSinceEpoch() end
local function log(v)
    v.at = now()
    local f = io.open(hs.configdir .. "/window-gateway.jsonl", "a")
    if f then f:write(hs.json.encode(v), "\n"); f:close() end
end
local function screen(uuid)
    for _, s in ipairs(hs.screen.allScreens()) do if s:getUUID() == uuid then return s end end
end
local function focus()
    local a = hs.application.frontmostApplication()
    local w = a and a:focusedWindow()
    return { pid = a and a:pid(), windowId = w and w:id() }, w
end
local _, initialWindow = focus()
g.userScreenUUID = previous and previous == hs._codexWindowGateway and previous.userScreenUUID
    or initialWindow and initialWindow:screen():getUUID()
local function ready()
    local sidecar = hs._codexComputerUseSidecar
    return hs.settings.get("codexComputerUseSafetySuspended") ~= true
        and sidecar and sidecar.enabled
end
local function normal(w)
    return w and w:role() == "AXWindow" and w:subrole() == "AXStandardWindow"
end
local function windows(bundle)
    local out = {}
    for _, a in ipairs(hs.application.applicationsForBundleID(bundle) or {}) do
        for _, w in ipairs(a:allWindows()) do if normal(w) then out[w:id()] = w end end
    end
    return out
end
local function allWindowIDs(bundle)
    local out = {}
    for _, a in ipairs(hs.application.applicationsForBundleID(bundle) or {}) do
        for _, w in ipairs(a:allWindows()) do out[w:id()] = w end
    end
    return out
end
local function placement(intent)
    if intent ~= "automation" and intent ~= "review" and intent ~= "user" then return nil, "invalid_intent" end
    if not ready() then return nil, "auto_assignment_paused" end
    local mode = hs._codexComputerUseSidecar.placement
    local target = intent == "automation" and mode.mode == "fixed_screen" and screen(mode.fixedScreenUUID)
        or intent ~= "automation" and screen(g.userScreenUUID) or nil
    if intent == "automation" and mode.mode ~= "fixed_screen" then
        local all = hs.screen.allScreens()
        if #all ~= 2 or not screen(g.userScreenUUID) then return nil, "requires_two_connected_screens" end
        for _, s in ipairs(all) do if s:getUUID() ~= g.userScreenUUID then target = s end end
    end
    if not target then return nil, "target_screen_not_connected" end
    local f = target:frame()
    if f.w < 500 or f.h < 400 then return nil, "target_screen_too_small" end
    local display = target:fullFrame()
    return { enabled = true, intent = intent, targetScreenUUID = target:getUUID(), targetDisplayID = target:id(),
        displayBounds = { x=math.floor(display.x), y=math.floor(display.y),
            width=math.floor(display.w), height=math.floor(display.h) },
        bounds = { left = math.floor(f.x + 40), top = math.floor(f.y + 40),
            width = math.floor(math.min(1100, f.w - 80)), height = math.floor(math.min(800, f.h - 80)),
            focused = false, state = "normal" } }
end
g.placementForIntent = placement

local function planAvailable(plan)
    if not ready() then return nil, "auto_assignment_paused" end
    local target = screen(plan.targetScreenUUID)
    if not target then return nil, "target_screen_not_connected" end
    if target:id() ~= plan.targetDisplayID then return nil, "target_display_changed" end
    local frame, expected = target:fullFrame(), plan.displayBounds
    for native, saved in pairs({x="x",y="y",w="width",h="height"}) do
        if math.floor(frame[native]) ~= expected[saved] then return nil, "target_display_layout_changed" end
    end
    return true
end

function g.status()
    local sidecar = hs._codexComputerUseSidecar
    local plan, reason = placement("automation")
    local active, native = 0, 0
    for _, p in pairs(g.pending or {}) do
        if p.task and p.task:isRunning() or p.copyTask and p.copyTask:isRunning() then active=active+1 end
        if p.kind == "native_pending" and not p.completed then native=native+1 end
    end
    return { safetySuspended=hs.settings.get("codexComputerUseSafetySuspended")==true,
        assignmentEnabled=sidecar and sidecar.enabled==true or false,
        gatewayReady=plan~=nil, reason=reason, placement=plan, activeOwnedWorkers=active,
        activeNativeRequests=native }
end

function g.begin(intent, bundle, userRequestedMain)
    if intent ~= "automation" and userRequestedMain ~= true then
        return nil, "explicit_user_main_screen_request_required"
    end
    local plan, reason = placement(intent)
    if not plan then return nil, reason end
    local baseline = {}
    for id in pairs(allWindowIDs(bundle)) do baseline[id] = true end
    g.sequence = g.sequence + 1
    local token = tostring(math.floor(now() * 1000)) .. ":" .. g.sequence
    g.tickets[token] = { intent = intent, bundle = bundle, plan = plan, baseline = baseline,
        physicalSequence = g.physicalSequence, expires = now() + 90, before = focus() }
    log({ event = "begin", requestID = token, bundleID = bundle, intent = intent, targetScreenUUID = plan.targetScreenUUID })
    return token, plan
end

function g.finish(token, id, expectedPID)
    local t = g.tickets[token]
    g.tickets[token] = nil
    local function reject(reason)
        g.results[token] = { ok = false, reason = reason, requestID = token }
        log({ event = "rejected", requestID = token, reason = reason })
        return nil, reason
    end
    if not t or t.expires < now() then return reject("expired_or_consumed_request") end
    if not ready() then return reject("auto_assignment_paused") end
    local available, reason = planAvailable(t.plan)
    if not available then return reject(reason) end
    local target = screen(t.plan.targetScreenUUID)
    if not id and t.physicalSequence ~= g.physicalSequence then return reject("exact_window_id_required_after_user_input") end
    local all = windows(t.bundle)
    local w = id and all[id]
    if not id then
        local count = 0
        for k, item in pairs(all) do if not t.baseline[k] then count = count + 1; w = item end end
        if count ~= 1 then return reject("new_window_not_unique") end
    end
    if not w or t.baseline[w:id()] then return reject("existing_or_unrelated_window_not_claimed") end
    local a = w:application()
    if expectedPID and a:pid() ~= expectedPID then return reject("process_does_not_match") end
    local beforeScreen = w:screen() and w:screen():getUUID()
    if beforeScreen ~= t.plan.targetScreenUUID then
        local ok = pcall(function() w:moveToScreen(target, true, true, 0) end)
        if not ok then return reject("window_move_failed") end
    end
    if not w:screen() or w:screen():getUUID() ~= t.plan.targetScreenUUID then return reject("window_position_not_confirmed") end
    g.owners[w:id()] = { pid = a:pid(), bundle=t.bundle, bundleID=t.bundle,
        appPath=t.appPath, displayName=t.displayName,
        connectionReady=t.connectionReady~=false, connectionReason=t.connectionReason,
        connectionMode=t.connectionMode, intent = t.intent, requestID = token, plan=t.plan }
    local after = focus()
    local result = { ok = true, requestID = token, windowId = w:id(), pid = a:pid(), intent = t.intent,
        targetScreenUUID = t.plan.targetScreenUUID, firstObservedScreenUUID = beforeScreen,
        movedAfterCreation = beforeScreen ~= t.plan.targetScreenUUID,
        foregroundChanged = after.pid ~= t.before.pid or after.windowId ~= t.before.windowId,
        appPath=t.appPath,bundleID=t.bundle,connectionReady=t.connectionReady~=false,
        displayName=t.displayName,connectionReason=t.connectionReason }
    g.results[token] = result
    log({ event = "created", result = result })
    return true, result
end

-- Check exact ownership before AND after a native action; never repair focus or
-- adopt a window from an old request. This only returns metadata, not UI text.
function g.guardNative(token, id, pid)
    local owner = g.owners[id]
    if not owner or owner.requestID~=token or owner.pid~=pid then return nil,"not_owned" end
    local available, reason = planAvailable(owner.plan)
    if not available then return nil,reason end
    local w = hs.window.get(id)
    if not w or w:application():pid()~=pid then return nil,"owned_window_unavailable" end
    if not w:screen() or w:screen():getUUID()~=owner.plan.targetScreenUUID then return nil,"owned_window_left_target" end
    if not owner.connectionReady then return nil,owner.connectionReason or "application_connection_not_unique" end
    if owner.connectionMode=="unique_application" then
        local apps=hs.application.applicationsForBundleID(owner.bundleID) or {}
        local ownedWindows=allWindowIDs(owner.bundleID)
        local count=0
        for _ in pairs(ownedWindows) do count=count+1 end
        if #apps~=1 or apps[1]:pid()~=pid or apps[1]:path()~=owner.appPath
            or count~=1 or not ownedWindows[id] then
            return nil,"application_connection_no_longer_unique"
        end
    end
    return {ok=true,requestID=token,pid=pid,windowId=id,targetScreenUUID=owner.plan.targetScreenUUID,
        appPath=owner.appPath,bundleID=owner.bundleID,displayName=owner.displayName,
        connectionReady=owner.connectionReady~=false,connectionMode=owner.connectionMode}
end

-- Chrome gives its own exact window/tab identifiers. Commit those directly;
-- typing in another app must not make us guess a macOS Accessibility window.
function g.checkBrowserRequest(token, extensionInstanceId, expectedPlacement)
    local t=g.tickets[token]
    if not t or t.bundle~=bundles.chrome or t.expires<now() then return nil,"expired_or_wrong_browser_request" end
    local available,reason=planAvailable(t.plan)
    if not available then return nil,reason end
    if t.intent~="automation" then return nil,"agent_browser_request_must_be_automation" end
    if not t.browserBaseline or not t.browserExtensionInstanceId
        or extensionInstanceId~=t.browserExtensionInstanceId then return nil,"browser_connection_mismatch" end
    if type(expectedPlacement)~="table" or expectedPlacement.targetScreenUUID~=t.plan.targetScreenUUID
        or expectedPlacement.intent~=t.plan.intent or type(expectedPlacement.bounds)~="table" then return nil,"browser_placement_mismatch" end
    for _,key in ipairs({"left","top","width","height","focused","state"}) do
        if expectedPlacement.bounds[key]~=t.plan.bounds[key] then return nil,"browser_placement_mismatch" end
    end
    return {ok=true,kind="browser",requestID=token,placement=t.plan,extensionInstanceId=extensionInstanceId}
end

function g.finishBrowser(token, record)
    local t = g.tickets[token]; g.tickets[token] = nil
    local function reject(reason) log({event="browser_rejected",requestID=token,reason=reason});return nil,reason end
    if not t or t.expires < now() or t.bundle ~= bundles.chrome then return reject("expired_or_wrong_browser_request") end
    if not planAvailable(t.plan) then return reject("target_unavailable_or_paused") end
    if not t.browserBaseline or type(record) ~= "table" or type(record.windowId) ~= "number"
        or type(record.tabId) ~= "number" or type(record.extensionInstanceId) ~= "string"
        or record.extensionInstanceId == "" or t.browserBaseline[record.windowId] then return reject("new_browser_window_proof_required") end
    if t.browserExtensionInstanceId and t.browserExtensionInstanceId~=record.extensionInstanceId then
        return reject("browser_connection_mismatch")
    end
    local b = record.bounds
    if type(b) ~= "table" or b.focused ~= false then return reject("browser_became_focused") end
    for _, k in ipairs({"left","top","width","height","state"}) do
        if b[k] ~= t.plan.bounds[k] then return reject("browser_initial_bounds_mismatch") end
    end
    local key = record.extensionInstanceId .. ":" .. record.windowId
    local result = {ok=true,kind="browser",requestID=token,intent=t.intent,windowId=record.windowId,
        tabId=record.tabId,extensionInstanceId=record.extensionInstanceId,targetScreenUUID=t.plan.targetScreenUUID,
        userInputEventsDuringOpen=g.physicalSequence-t.physicalSequence,focused=false}
    g.browserOwners[key] = result;g.results[token]=result
    log({event="browser_created",result=result});return true,result
end

local function quote(s) return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"' end
function g.openFinderWindow(intent, directory, options)
    if type(directory) ~= "string" or directory:sub(1, 1) ~= "/" or directory:find("[%z\r\n]")
        or hs.fs.attributes(directory, "mode") ~= "directory" then return nil, { reason = "directory_required" } end
    local token, plan = g.begin(intent, bundles.finder, options and options.userRequestedMain)
    if not token then return nil, { reason = plan } end
    local b = plan.bounds
    local code = string.format([[with timeout of 2 seconds
tell application id "com.apple.finder"
set newWindow to make new Finder window with properties {target:(POSIX file %s as alias), bounds:{%d,%d,%d,%d}}
set target of newWindow to (POSIX file %s as alias)
set bounds of newWindow to {%d,%d,%d,%d}
set index of newWindow to (count of Finder windows)
return {id of newWindow, POSIX path of (target of newWindow as alias), index of newWindow}
end tell
end timeout]], quote(directory), b.left, b.top, b.left + b.width, b.top + b.height, quote(directory),
        b.left, b.top, b.left + b.width, b.top + b.height)
    local ok, value, err = hs.osascript.applescript(code)
    local id = type(value) == "table" and tonumber(value[1])
    local actualPath = type(value) == "table" and value[2]
    if not ok or not id or type(actualPath) ~= "string" then
        g.tickets[token] = nil
        log({ event = "finder_failed", requestID = token, error = err })
        return nil, { reason = "finder_create_failed", error = err }
    end
    local expected = hs.fs.attributes(directory)
    local actual = hs.fs.attributes(actualPath)
    local targetCorrect = expected and actual and expected.ino == actual.ino and expected.dev == actual.dev
    local success, result = g.finish(token, id)
    if type(result) == "table" then
        result.targetDirectoryVerified = targetCorrect == true
        result.backgroundWindowIndex=tonumber(value[3])
    end
    if not targetCorrect then
        log({event="finder_target_mismatch",requestID=token,windowId=id})
        if success then g.closeOwnWindow(id,result.pid) end
        return nil,{reason="finder_target_mismatch"}
    end
    return success, type(result) == "table" and result or { reason = result }
end

local function write(path, value)
    local f = assert(io.open(path, "w")); f:write(value); f:close()
end
function g.openObsidianWindow(intent, options)
    local descriptor = io.open(hs.configdir .. "/codex-obsidian-worker/worker.json", "r")
    if not descriptor or not descriptor.read then return nil, "worker_not_installed" end
    local decoded, worker = pcall(hs.json.decode, descriptor:read("*a")); descriptor:close()
    local buildDirectory=type(worker)=="table" and type(worker.appPath)=="string"
        and worker.appPath:match("^(.*)/[^/]+%.app$") or nil
    local workerRoot=buildDirectory and buildDirectory:match("^(.*)/[^/]+$")
    if not decoded or type(worker) ~= "table" or worker.bundleID ~= bundles.obsidian
        or type(worker.appPath) ~= "string" or worker.appPath:find(hs.configdir .. "/codex-obsidian-worker/", 1, true) ~= 1
        or worker.executable ~= worker.appPath .. "/Contents/MacOS/Obsidian"
        or not buildDirectory or hs.fs.attributes(worker.executable, "mode") ~= "file" then return nil, "invalid_worker_installation" end
    if worker.backgroundProtocolVersion~=1 then return nil,"worker_update_required" end
    if not workerRoot or workerRoot~=hs.configdir.."/codex-obsidian-worker" then return nil,"invalid_worker_installation" end
    local token, plan = g.begin(intent, bundles.obsidian, options.userRequestedMain)
    if not token then return nil, plan end
    local workerBundleID=worker.bundleID
    g.tickets[token].obsidianWorker=true
    -- Each invocation makes a fresh profile AND empty vault. It never registers
    -- or opens a personal vault. No plugin is copied, disabled, or changed.
    local root = options.runtimeRoot or (hs.configdir .. "/codex-window-runtime")
    if hs.fs.attributes(root, "mode") ~= "directory" then assert(hs.fs.mkdir(root)) end
    local run = root .. "/obsidian-" .. token:gsub(":", "-")
    assert(hs.fs.mkdir(run)); assert(hs.fs.mkdir(run .. "/profile")); assert(hs.fs.mkdir(run .. "/vault"))
    local taskWorkerRoot=workerRoot.."/tasks"
    if hs.fs.attributes(taskWorkerRoot,"mode")~="directory" then assert(hs.fs.mkdir(taskWorkerRoot)) end
    local workerTaskDirectory=taskWorkerRoot.."/"..token:gsub(":","-")
    if hs.fs.attributes(workerTaskDirectory,"mode")~="directory" then assert(hs.fs.mkdir(workerTaskDirectory)) end
    local workerApp=workerTaskDirectory.."/Codex Obsidian Workspace.app"
    local workerExecutable=workerApp.."/Contents/MacOS/Obsidian"
    local vaultID, b = "c0de5c0de5c0de50", plan.bounds
    write(run .. "/profile/obsidian.json", hs.json.encode({ updateDisabled = true, vaults = {
        [vaultID] = { path = run .. "/vault", ts = math.floor(now() * 1000), open = true } } }))
    write(run .. "/profile/" .. vaultID .. ".json", hs.json.encode({ x=b.left, y=b.top,
        width=b.width, height=b.height, isMaximized=false }))
    write(run .. "/vault/窗口测试.md", "# 独立窗口测试\n\n此文件不属于个人笔记库。\n")
    local function control(enabled, reason, foregroundAllowed)
        local file=run.."/control.json"
        write(file..".tmp",hs.json.encode({protocolVersion=1,requestID=token,enabled=enabled,
            foregroundAllowed=foregroundAllowed==true,reason=reason}))
        assert(os.rename(file..".tmp",file))
    end
    control(true,nil,false)
    write(run .. "/workspace.json", hs.json.encode({ profile=run.."/profile",vault=run.."/vault",
        workerExecutable=workerExecutable,bounds=b,screenUUID=plan.targetScreenUUID,requestID=token,
        displayID=plan.targetDisplayID,displayBounds=plan.displayBounds,controlFile=run.."/control.json" }))
    -- Obsidian's current installer unlinks ~/.obsidian-cli.sock even with a
    -- private --user-data-dir. Deny those writes in THIS test process; do not
    -- move the socket, change HOME, restart, or patch the user's application.
    local userDir = os.getenv("HOME")
    local policy = '(version 1)\n(allow default)\n(deny file-write* (literal '
        .. quote(userDir .. "/.obsidian-cli.sock") .. '))\n'
        .. '(deny file-write* (subpath ' .. quote(userDir .. "/Library/Application Support/obsidian") .. '))\n'
    for _, p in ipairs(options.protectedDirectories or {}) do
        policy = policy .. '(deny file-write* (subpath ' .. quote(p) .. '))\n'
    end
    -- Chromium's helpers install their own native sandbox. Exempt ONLY these
    -- exact helper executables from inheriting our extra main-process policy;
    -- otherwise Chromium aborts when it tries to nest the two sandboxes.
    -- No --no-sandbox / --disable-*-sandbox switch is used.
    for _, name in ipairs({"Obsidian Helper", "Obsidian Helper (GPU)", "Obsidian Helper (Renderer)", "Obsidian Helper (Plugin)"}) do
        local sourceExecutable = worker.appPath .. "/Contents/Frameworks/" .. name .. ".app/Contents/MacOS/" .. name
        local executable = workerApp .. "/Contents/Frameworks/" .. name .. ".app/Contents/MacOS/" .. name
        if hs.fs.attributes(sourceExecutable, "mode") == "file" then
            policy = policy .. '(allow process-exec (literal ' .. quote(executable) .. ') (with no-sandbox))\n'
        end
    end
    write(run .. "/protect-personal.sb", policy)
    local pending = { kind="native_pending",requestID=token,placement=plan,profile=run.."/profile",vault=run.."/vault",
        workerApp=workerApp,workerBundleID=workerBundleID,backgroundEvents={} }
    pending.disableForeground=function(reason)control(false,reason,false)end
    local function cleanupWorkerCopy()
        if workerTaskDirectory:find(taskWorkerRoot.."/",1,true)~=1 then return end
        local cleanup=hs.task.new("/bin/rm",function()end,function()return true end,{"-rf",workerTaskDirectory})
        if cleanup then pending.cleanupTask=cleanup;cleanup:start() end
    end
    local function failBeforeStart(reason)
        g.tickets[token]=nil
        pcall(control,false,reason,false)
        g.results[token]={ok=false,reason=reason,requestID=token}
        cleanupWorkerCopy()
    end
    local function launchWorker()
    local startupError = ""
    local outputBuffer = ""
    local task = hs.task.new("/usr/bin/sandbox-exec", function(code)
        pending.exitCode=code;pending.startupError=startupError
        log({ event = "obsidian_exit", requestID = token, exitCode = code, error = startupError })
        cleanupWorkerCopy()
    end, function(_, output, err)
        startupError=(startupError .. (err or "")):sub(1,2000)
        outputBuffer=(outputBuffer .. (output or "")):sub(-8192)
        for line in outputBuffer:gmatch("([^\n]*)\n") do
            local payload=line:match("^CODEX_OBSIDIAN_BG (.+)$")
            if payload then
                local ok,event=pcall(hs.json.decode,payload)
                if ok and event.pid==pending.pid and event.requestID==token then
                    if #pending.backgroundEvents<100 then pending.backgroundEvents[#pending.backgroundEvents+1]=event end
                    if event.event=="installed" then pending.backgroundReady=true end
                    if type(event.event)=="string" then pending.suspendedReason=event.event:match("^suspended:(.+)$") or pending.suspendedReason end
                end
            end
        end
        outputBuffer=outputBuffer:match("([^\n]*)$") or ""
        return true
    end, { "-f", run .. "/protect-personal.sb",workerExecutable,
        "--user-data-dir=" .. run .. "/profile","--codex-workspace-config="..run.."/workspace.json",run .. "/vault" })
    if not task or not task:start() then failBeforeStart("obsidian_launch_failed");return end
    pending.pid=task:pid();pending.task=task
    local attempts, accepted = 0, false
    local function fail(reason, terminate)
        if pending.timer then pending.timer:stop() end
        g.tickets[token]=nil
        local wrote=pcall(control,false,reason,false)
        if not wrote then reason="worker_control_update_failed";terminate=true end
        g.results[token]={ok=false,reason=reason,requestID=token,pid=pending.pid,
            exitCode=pending.exitCode,error=pending.startupError}
        if terminate and task:isRunning() then task:terminate() end
    end
    pending.timer = hs.timer.doEvery(0.15, function()
        local available, reason=planAvailable(plan)
        if not available then fail(reason,not accepted);return end
        if pending.suspendedReason then fail(pending.suspendedReason,not accepted);return end
        if not task:isRunning() then
            if accepted then pending.timer:stop() else fail("obsidian_exited_before_ready",false) end
            return
        end
        if accepted then return end
        attempts = attempts + 1
        local a = pending.backgroundReady and hs.application.applicationForPID(pending.pid)
        local own = {}
        if a and a:bundleID() == workerBundleID then
            for _, w in ipairs(a:allWindows()) do if normal(w) then own[#own + 1] = w end end
        end
        if #own == 1 and pending.backgroundReady then
            local ok,result=g.finish(token,own[1]:id(),pending.pid)
            if ok then
                local enabled=pcall(control,true,nil,true)
                if not enabled then
                    g.closeOwnWindow(result.windowId,result.pid)
                    fail("worker_control_update_failed",true)
                    return
                end
                result.backgroundBootstrapInstalled=true
                pending.connectionReady=result.connectionReady
                pending.connectionReason=result.connectionReason
                accepted=true
            else fail(type(result)=="string" and result or "obsidian_registration_failed",true) end
        elseif #own > 1 or attempts >= 200 then
            fail(#own > 1 and "new_window_not_unique" or "obsidian_window_unavailable",true)
        end
    end)
    end
    g.pending = g.pending or {}; g.pending[token] = pending
    local function prepare(executable,args,nextStep,errorReason)
        local task
        task=hs.task.new(executable,function(code)
            if pending.copyTask==task then pending.copyTask=nil end
            if code~=0 then failBeforeStart(errorReason);return end
            local available,reason=planAvailable(plan)
            if not available then failBeforeStart(reason);return end
            nextStep()
        end,function()return true end,args)
        pending.copyTask=task
        if not task or not task:start() then
            pending.copyTask=nil
            failBeforeStart(errorReason)
            return false
        end
        return true
    end
    local started=prepare("/bin/cp",{"-cR",worker.appPath,workerApp},function()
        prepare("/usr/bin/codesign",{"--verify","--strict",workerApp},launchWorker,"worker_signature_invalid")
    end,"worker_copy_failed")
    if not started then
        g.pending[token]=nil
        return nil,"worker_copy_failed"
    end
    return pending
end

local function nativeLauncherPath()
    local home=os.getenv("HOME")
    return home and (home.."/.codex/window-routing/current/bin/native-app-launcher") or nil
end

function g.openNativeApp(intent, selector)
    if type(selector)~="string" or selector=="" or selector:find("[%z\r\n]") then
        return nil,"application_selector_required"
    end
    local plan,placementReason=placement(intent)
    if not plan then return nil,placementReason end
    g.sequence=g.sequence+1
    local token=tostring(math.floor(now()*1000))..":"..g.sequence
    local ticket={intent=intent,plan=plan,expires=now()+180,before=focus(),
        physicalSequence=g.physicalSequence,baseline={},connectionReady=false}
    local pending={kind="native_pending",requestID=token,selector=selector,placement=plan,
        backgroundEvents={},startedAt=now(),completed=false,connectionReady=false}
    g.tickets[token]=ticket
    g.pending[token]=pending

    local function fail(reason,detail)
        if pending.timer then pending.timer:stop();pending.timer=nil end
        pending.completed=true
        g.tickets[token]=nil
        ticket.connectionReady=false;ticket.connectionReason=reason
        pending.connectionReady=false;pending.connectionReason=reason
        g.results[token]={ok=false,requestID=token,reason=reason,detail=detail,
            appPath=pending.appPath,bundleID=pending.bundleID,pid=pending.pid,
            windowId=pending.windowId,targetScreenUUID=plan.targetScreenUUID,connectionReady=false,
            connectionReason=reason}
        log({event="native_app_rejected",requestID=token,reason=reason,detail=detail})
    end

    local function runHelper(action,value,callback)
        local executable=nativeLauncherPath()
        if not executable or hs.fs.attributes(executable,"mode")~="file" then
            callback(false,nil,"native_app_launcher_not_installed")
            return
        end
        local output,errorOutput="",""
        local task=hs.task.new(executable,function(code)
            local decoded,parseError
            for line in output:gmatch("([^\n]+)") do
                local ok,value=pcall(hs.json.decode,line)
                if ok and type(value)=="table" then decoded=value end
            end
            callback(code==0,decoded,errorOutput~="" and errorOutput or parseError)
        end,function(_,stdout,stderr)
            output=(output..(stdout or "")):sub(-16384)
            errorOutput=(errorOutput..(stderr or "")):sub(-4096)
            return true
        end,{action,value})
        if not task or not task:start() then
            callback(false,nil,"native_app_launcher_start_failed")
            return
        end
        pending.helperTask=task
    end

    runHelper("resolve",selector,function(resolved,identity,resolveError)
        if not resolved or type(identity)~="table" or type(identity.bundleID)~="string"
            or type(identity.appPath)~="string" then
            fail(type(identity)=="table" and identity.reason or resolveError or "application_resolution_failed")
            return
        end
        if identity.bundleID==bundles.chrome then fail("use_chrome_gateway");return end
        if identity.bundleID==bundles.finder then fail("use_finder_gateway");return end
        if identity.bundleID=="md.obsidian" then fail("obsidian_isolation_adapter_required");return end
        pending.appPath=identity.appPath
        pending.bundleID=identity.bundleID
        pending.displayName=identity.displayName
        ticket.bundle=identity.bundleID
        ticket.appPath=identity.appPath
        ticket.displayName=identity.displayName
        ticket.connectionMode="unique_application"
        ticket.baseline=allWindowIDs(identity.bundleID)
        ticket.baselinePIDs={}
        for _,app in ipairs(hs.application.applicationsForBundleID(identity.bundleID) or {}) do
            ticket.baselinePIDs[app:pid()]=true
        end
        runHelper("launch",identity.appPath,function(launched,launchResult,launchError)
            if not launched or type(launchResult)~="table" or launchResult.ok~=true
                or launchResult.bundleID~=identity.bundleID or launchResult.appPath~=identity.appPath
                or type(launchResult.pid)~="number" then
                fail(type(launchResult)=="table" and launchResult.reason or launchError or "application_launch_failed")
                return
            end
            if ticket.baselinePIDs[launchResult.pid] then fail("existing_application_reused");return end
            pending.createdByRequest=true
            pending.pid=launchResult.pid
            local attempts=0
            pending.timer=hs.timer.doEvery(0.15,function()
                local available,reason=planAvailable(plan)
                if not available then fail(reason);return end
                attempts=attempts+1
                local app=hs.application.applicationForPID(pending.pid)
                if app and (app:bundleID()~=identity.bundleID or app:path()~=identity.appPath) then
                    fail("launched_application_identity_mismatch");return
                end
                if app then
                    pending.task=app
                    local own={}
                    for _,window in ipairs(app:allWindows()) do if normal(window) then own[#own+1]=window end end
                    if #own>1 then fail("new_application_window_ambiguous");return end
                    if #own==1 then
                        local id=own[1]:id()
                        if ticket.baseline[id] then fail("existing_window_not_claimed");return end
                        local allApps=hs.application.applicationsForBundleID(identity.bundleID) or {}
                        local all=allWindowIDs(identity.bundleID)
                        local allCount=0
                        for _ in pairs(all) do allCount=allCount+1 end
                        ticket.connectionReady=#allApps==1 and allApps[1]:pid()==pending.pid
                            and allCount==1 and all[id]~=nil and next(ticket.baselinePIDs)==nil
                        ticket.connectionReason=ticket.connectionReady and nil or "application_identity_not_unique"
                        local ok,result=g.finish(token,id,pending.pid)
                        if not ok then fail(type(result)=="string" and result or "application_window_registration_failed");return end
                        pending.windowId=result.windowId
                        pending.targetScreenUUID=result.targetScreenUUID
                        pending.connectionReady=result.connectionReady
                        pending.connectionReason=result.connectionReason
                        pending.completed=true
                        pending.app=app
                        pending.timer:stop();pending.timer=nil
                        g.results[token]=result
                        log({event="native_app_created",result=result,displayName=identity.displayName})
                        return
                    end
                end
                if attempts>=200 then fail("application_window_not_available");return end
            end)
        end)
    end)
    return pending
end

function g.open(intent, application, options)
    options = options or {}
    if application=="app" then return g.openNativeApp(intent,options.applicationSelector) end
    if not bundles[application] then return nil, "unsupported_application" end
    if not ready() then return nil, "auto_assignment_paused" end
    if application == "obsidian" then return g.openObsidianWindow(intent, options) end
    if application == "finder" then
        local ok, result = g.openFinderWindow(intent, options.directory, options)
        return ok and result or nil, not ok and result or nil
    end
    local token, plan = g.begin(intent, bundles.chrome, options.userRequestedMain)
    if not token then return nil, plan end
    if type(options.browserBaselineIDs)=="table" then
        g.tickets[token].browserBaseline={}
        for _, id in ipairs(options.browserBaselineIDs)do g.tickets[token].browserBaseline[id]=true end
    end
    if type(options.browserExtensionInstanceId)=="string" and options.browserExtensionInstanceId~="" then
        g.tickets[token].browserExtensionInstanceId=options.browserExtensionInstanceId
    end
    return { kind = "browser", requestID = token, placement = plan,extensionInstanceId=options.browserExtensionInstanceId }
end

function g.closeOwnWindow(id, pid)
    local owner, w = g.owners[id], hs.window.get(id)
    if not owner or not w or owner.pid ~= pid or w:application():pid() ~= pid then return nil, "not_owned" end
    for _,pending in pairs(g.pending or {}) do
        if pending.requestID==owner.requestID and pending.disableForeground then
            pcall(pending.disableForeground,"task_window_closed")
            break
        end
    end
    w:close()
    local result=g.results[owner.requestID]
    if result then result.ok=false;result.connectionReady=false;result.reason="task_window_closed" end
    g.owners[id] = nil
    return true
end
function g.stop()
    if g.tap then g.tap:stop() end
    -- Do not disable a live worker's safety monitor during a module reload.
    -- Its closure remains responsible for its own process and control file.
    for _, p in pairs(g.pending or {}) do
        if p.copyTask and p.copyTask:isRunning() then p.copyTask:terminate() end
        if p.helperTask and p.helperTask:isRunning() then p.helperTask:terminate() end
        if p.timer and (not p.task or not p.task:isRunning()) then p.timer:stop() end
    end
end
-- Read-only input origin/count, never characters. A real click or key updates
-- the user's screen after focus settles. Agent activation never flips it.
g.tap = hs.eventtap.new({hs.eventtap.event.types.leftMouseDown, hs.eventtap.event.types.keyDown}, function(e)
    local p = hs.eventtap.event.properties
    if e:getProperty(p.eventSourceUnixProcessID) == 0 and e:getProperty(p.eventSourceStateID) == 1 then
        g.physicalSequence = g.physicalSequence + 1
        local sequence = g.physicalSequence
        hs.timer.doAfter(0.05, function()
            if g.physicalSequence ~= sequence then return end
            local _, w = focus()
            if w and w:screen() then g.userScreenUUID = w:screen():getUUID() end
        end)
    end
    return false
end):start()
hs._codexExternalWindowRouter = g
hs._codexWindowGateway = g
return g
