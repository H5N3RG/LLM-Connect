-- ===========================================================================
--  gui/code_executor.lua — legacy shim
--
--  v1.1.0-dev: the real execution backend lives at /runtime/core_executor.lua.
--  This file exists only so old IDE references and external experiments do not
--  break during the migration.
-- ===========================================================================

local ex = _G.core_executor or (_G.llm_connect and _G.llm_connect.core_executor)

if not ex then
    local path = core.get_modpath("llm_connect") .. "/runtime/core_executor.lua"
    local ok, result = pcall(dofile, path)
    if not ok then
        error("[code_executor shim] core_executor.lua unavailable: " .. tostring(result))
    end
    ex = result
end

core.log("warning", "[code_executor] deprecated shim loaded; use core_executor.lua")

return ex
