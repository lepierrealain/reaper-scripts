-- @description Select item under mouse cursor
-- @author lepierrealain
-- @version 1.0

local lib_path = ({ reaper.get_action_context() })[2]:match("^(.+[\\/])")
dofile(lib_path .. "PA_lib_mouse.lua")

local function main()
  local item = PA_GetItemUnderMouse()

  if not item then
    return
  end

  reaper.Undo_BeginBlock()
  reaper.SelectAllMediaItems(0, false)
  reaper.SetMediaItemSelected(item, true)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Select item under mouse cursor", -1)
end

main()
