-- codex-computer-use-sidecar-loader v1
-- PiP placement plus one explicit opening gateway. The legacy Dock/menu
-- inference router and the global diagnostic observer are not auto-loaded.
require("hs.ipc")
-- Incident containment: leave all project window/Accessibility observers unloaded.
-- This flag survives login; investigating a crash must not silently resume them.
if hs.settings.get("codexComputerUseSafetySuspended") == true then
    hs._codexSafetyMenu = hs.menubar.new()
    hs._codexSafetyMenu:setTitle("CU 暂停排查")
    hs._codexSafetyMenu:setMenu({{title="自动分配与观察已暂停",disabled=true}})
    return
end
package.path = package.path .. ";" .. hs.configdir .. "/?.lua"
dofile(hs.configdir .. "/computer_use_sidecar.lua")
dofile(hs.configdir .. "/window_gateway.lua")
