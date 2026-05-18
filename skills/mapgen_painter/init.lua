-- Generic skill gateway. The registry discovers this file by structure.

local core = core
local modpath = core.get_modpath(core.get_current_modname())

return dofile(modpath .. "/skills/mapgen_painter/mapgen_painter.lua")
