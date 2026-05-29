-- @description Split all items at mouse cursor
-- @author lepierrealain
-- @version 1.0

local lib_path = ({ reaper.get_action_context() })[2]:match("^(.+[\\/])")
dofile(lib_path .. "PA_lib_mouse.lua")

local function main()
  local _, mouse_time = PA_GetMouseArrangeContext()
  if not mouse_time then return end

  local snap_enabled = reaper.GetToggleCommandState(1157) == 1
  local split_time = snap_enabled and reaper.SnapToGrid(0, mouse_time) or mouse_time

  reaper.Undo_BeginBlock()

  for t = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, t)
    for i = reaper.CountTrackMediaItems(track) - 1, 0, -1 do
      local item = reaper.GetTrackMediaItem(track, i)
      local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local item_end   = item_start + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      if split_time > item_start and split_time < item_end then
        reaper.SplitMediaItem(item, split_time)
      end
    end
  end

  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Split all items at mouse cursor", -1)
end

main()
