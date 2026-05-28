-- @description Split item under mouse cursor
-- @author lepierrealain
-- @version 1.0

local lib_path = ({ reaper.get_action_context() })[2]:match("^(.+[\\/])")
dofile(lib_path .. "PA_lib_mouse.lua")

local function main()
  local item, mouse_time = PA_GetItemUnderMouse()
  if not item then return end

  local snap_enabled = reaper.GetToggleCommandState(1157) == 1
  local split_time = snap_enabled and reaper.SnapToGrid(0, mouse_time) or mouse_time

  reaper.Undo_BeginBlock()
  reaper.SplitMediaItem(item, split_time)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Split item under mouse cursor", -1)
end

main()
