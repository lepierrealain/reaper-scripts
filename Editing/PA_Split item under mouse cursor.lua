-- @description Split item under mouse cursor
-- @author lepierrealain
-- @version 1.0

local lib_path = ({ reaper.get_action_context() })[2]:match("^(.+[\\/])")
dofile(lib_path .. "PA_lib_mouse.lua")

local function main()
  local item, mouse_time = PA_GetItemUnderMouse()
  if not item then return end

  reaper.Undo_BeginBlock()
  reaper.SplitMediaItem(item, mouse_time)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Split item under mouse cursor", -1)
end

main()
