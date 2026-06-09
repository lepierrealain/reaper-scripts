-- @description Set snap offset at mouse cursor
-- @author lepierrealain
-- @version 1.0

local lib_path = ({ reaper.get_action_context() })[2]:match("^(.+[\\/])")
local lib_root = lib_path .. ".." .. package.config:sub(1,1) .. "Libraries" .. package.config:sub(1,1)
dofile(lib_root .. "PA_lib_mouse.lua")
dofile(lib_root .. "PA_lib_item.lua")

local function main()
  local item, mouse_time = PA_GetItemUnderMouse()
  if not item then return end

  local snap_enabled = reaper.GetToggleCommandState(1157) == 1
  local snap_time = snap_enabled and reaper.SnapToGrid(0, mouse_time) or mouse_time

  local item_start  = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local snap_offset = snap_time - item_start

  local grouped = PA_GetRelatedItemsAtSamePosition(item)

  reaper.Undo_BeginBlock()
  reaper.SetMediaItemInfo_Value(item, "D_SNAPOFFSET", snap_offset)
  for _, gi in ipairs(grouped) do
    reaper.SetMediaItemInfo_Value(gi, "D_SNAPOFFSET", snap_offset)
  end
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Set snap offset at mouse cursor", -1)
end

main()
