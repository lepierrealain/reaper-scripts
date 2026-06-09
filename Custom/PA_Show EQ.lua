-- @description Show EQ on track under mouse (add if missing, picker if multiple)
-- @author lepierrealain
-- @version 1.0
-- @requires js_ReaScriptAPI, ReaImGui

local lib_path = ({ reaper.get_action_context() })[2]:match("^(.+[\\/])")
local lib_root = lib_path .. ".." .. package.config:sub(1,1) .. "Libraries" .. package.config:sub(1,1)
dofile(lib_root .. "PA_lib_show_fx.lua")

PA_ShowFX("eq", "/q", "Show EQ", ({ reaper.get_action_context() })[2])
