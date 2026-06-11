-- @description Duplicate item to track under mouse
-- @author lepierrealain
-- @version 1.0

local lib_path = ({ reaper.get_action_context() })[2]:match("^(.+[\\/])")
local lib_root = lib_path .. ".." .. package.config:sub(1,1) .. "Libraries" .. package.config:sub(1,1)
dofile(lib_root .. "PA_lib_mouse.lua")

local function main()
  if reaper.CountSelectedMediaItems(0) == 0 then return end

  local dest_track = PA_GetMouseArrangeContext()
  if not dest_track then return end

  local items = {}
  for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
    items[#items + 1] = reaper.GetSelectedMediaItem(0, i)
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  reaper.SelectAllMediaItems(0, false)

  for _, item in ipairs(items) do
    local pos      = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local _, chunk = reaper.GetItemStateChunk(item, "", false)
    local new_item = reaper.AddMediaItemToTrack(dest_track)
    reaper.SetItemStateChunk(new_item, chunk, false)
    reaper.SetMediaItemPosition(new_item, pos, false)
    reaper.SetMediaItemSelected(new_item, true)
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Duplicate item to track under mouse", -1)
end

main()
