-- @description Add EQ on selected track (always add, never show existing)
-- @author lepierrealain
-- @version 1.0
-- @requires js_ReaScriptAPI, ReaImGui

local lib_path = ({ reaper.get_action_context() })[2]:match("^(.+[\\/])")
local lib_root = lib_path .. ".." .. package.config:sub(1,1) .. "Libraries" .. package.config:sub(1,1)
dofile(lib_root .. "PA_lib_show_fx.lua")

PA_AddFX("eq", "/q", "Add EQ", ({ reaper.get_action_context() })[2])
