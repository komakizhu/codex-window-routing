-- Read-only status. Safe even when init.lua has deliberately unloaded routing.
-- From the repository root: hs ./hammerspoon/window_status.lua
local sidecar,gateway=hs._codexComputerUseSidecar,hs._codexWindowGateway
local state={safetySuspended=hs.settings.get("codexComputerUseSafetySuspended")==true,
    savedAssignmentEnabled=hs.settings.get("codexComputerUseSidecarEnabled"),
    sidecarLoaded=sidecar~=nil,gatewayLoaded=gateway~=nil,
    assignmentEnabled=sidecar and sidecar.enabled==true or false}
if gateway and gateway.status then
    state.gateway=gateway.status()
elseif gateway and gateway.placementForIntent then
    local plan,reason=gateway.placementForIntent("automation")
    state.gateway={gatewayReady=plan~=nil,reason=reason,placement=plan,legacyRuntime=true}
else
    state.gateway={gatewayReady=false,reason=state.safetySuspended and "safety_suspended" or "gateway_not_loaded"}
end
state.nativeInputIsolationVerified=false
state.nativeInputNote="Codex 支持后台独立光标；本项目的输入验收仍未通过，当前只验收窗口来源和屏幕分流。"
print(hs.json.encode(state))
