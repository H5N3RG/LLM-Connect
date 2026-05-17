-- Generic skill gateway. The registry discovers this file by structure.

local core = core
local modpath = core.get_modpath(core.get_current_modname())

return dofile(modpath .. "/skills/worldedit_agent/worldedit_agent.lua")
