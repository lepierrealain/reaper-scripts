-- @description Select all items on track under mouse cursor
-- @author lepierrealain
-- @version 1.0

local lib_path = ({ reaper.get_action_context() })[2]:match("^(.+[\\/])")
local lib_root = lib_path .. ".." .. package.config:sub(1,1) .. "Libraries" .. package.config:sub(1,1)
dofile(lib_root .. "PA_lib_mouse.lua")

local function main()
  local track = select(1, PA_GetMouseArrangeContext())
  if not track then return end

  reaper.Undo_BeginBlock()
  reaper.SelectAllMediaItems(0, false)
  for i = 0, reaper.CountTrackMediaItems(track) - 1 do
    reaper.SetMediaItemSelected(reaper.GetTrackMediaItem(track, i), true)
  end
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Select all items on track under mouse cursor", -1)
end

main()
