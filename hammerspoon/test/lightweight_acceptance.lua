-- Explicit, bounded acceptance audit. Never records input values or titles.
local root = assert(...)
local a = { root = root, phases = {} }
local function save()
    local f=assert(io.open(root.."/acceptance.json","w"));f:write(hs.json.encode(a.phases,true));f:close()
end
local function attr(e,k)
    if not e then return nil end
    local ok,v=pcall(function()return e:attributeValue(k)end);return ok and v or nil
end
local function snapshot()
    local app=hs.application.frontmostApplication();local w=app and app:focusedWindow()
    local ax=app and hs.axuielement.applicationElement(app)
    if ax then ax:setTimeout(0.05)end
    local e=attr(ax,"AXFocusedUIElement")
    local mouse=hs.mouse.absolutePosition()
    local sameInputElement
    if a.initialElement~=nil and e~=nil then sameInputElement=e==a.initialElement end
    return {at=hs.timer.secondsSinceEpoch(),pid=app and app:pid(),bundleID=app and app:bundleID(),
        windowId=w and w:id(),screenUUID=w and w:screen():getUUID(),elementRole=attr(e,"AXRole"),
        inputElementAvailable=e~=nil,
        sameInputElement=sameInputElement,
        physicalSequence=hs._codexWindowGateway.physicalSequence,mouse={x=mouse.x,y=mouse.y}},e
end
function a.start(label)
    assert(not a.current,"finish prior phase first")
    local first,e=snapshot();a.initialElement=e
    first.sameInputElement=e~=nil and true or nil
    a.current={label=label,first=first,samples={first},activations={}}
    a.watcher=hs.application.watcher.new(function(_,event,app)
        if event==hs.application.watcher.activated then
            a.current.activations[#a.current.activations+1]={at=hs.timer.secondsSinceEpoch(),pid=app:pid(),bundleID=app:bundleID()}
        end
    end):start()
    a.timer=hs.timer.doEvery(0.2,function()local v=snapshot();a.current.samples[#a.current.samples+1]=v end)
    a.watchdog=hs.timer.doAfter(45,function()if a.current then a.finish({reason="audit_time_limit"})end end)
    return first
end
function a.finish(details)
    if not a.current then return nil end
    a.timer:stop();a.watcher:stop();a.watchdog:stop()
    local last=snapshot();a.current.last=last;a.current.details=details
    local changed=0;local inputChanged=0
    for _,v in ipairs(a.current.samples)do
        if v.pid~=a.current.first.pid or v.windowId~=a.current.first.windowId then changed=changed+1 end
        if v.sameInputElement==false then inputChanged=inputChanged+1 end
    end
    a.current.focusChangedSamples=changed;a.current.inputChangedSamples=inputChanged
    a.phases[#a.phases+1]=a.current;local r=a.current;a.current=nil;save()
    return {label=r.label,samples=#r.samples,focusChangedSamples=changed,inputChangedSamples=inputChanged,
        activations=r.activations,first=r.first,last=r.last,details=details}
end
function a.snapshot()local v=snapshot();return v end
function a.window(id)
    local w=hs.window.get(id);if not w then return nil end
    local f=w:frame();local app=w:application()
    return {id=id,pid=app:pid(),bundleID=app:bundleID(),screenUUID=w:screen():getUUID(),frame={x=f.x,y=f.y,w=f.w,h=f.h}}
end
return a
