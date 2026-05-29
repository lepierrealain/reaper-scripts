-- @description Add fade out to item under mouse cursor
-- @author lepierrealain
-- @version 1.0

local lib_path = ({ reaper.get_action_context() })[2]:match("^(.+[\\/])")
dofile(lib_path .. "PA_lib_mouse.lua")
dofile(lib_path .. "PA_lib_item.lua")

local function is_item_visible(item)
  local view_start, view_end = reaper.GetSet_ArrangeView2(0, false, 0, 0)
  local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_end   = item_start + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  return item_start < view_end and item_end > view_start
end

local function get_first_item_to_left(track, time)
  local num_items = reaper.CountTrackMediaItems(track)
  local closest, closest_end = nil, -math.huge
  for i = 0, num_items - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_end   = item_start + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    if item_end < time and item_end > closest_end then
      closest = item
      closest_end = item_end
    end
  end
  return closest
end

local function apply_fadeout(item, fade_len)
  local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", math.min(fade_len, item_len))
end

local function main()
  local snap_enabled = reaper.GetToggleCommandState(1157) == 1
  local track, mouse_time = PA_GetMouseArrangeContext()
  if not track then return end

  local fade_time = snap_enabled and reaper.SnapToGrid(0, mouse_time) or mouse_time

  local item, _ = PA_GetItemUnderMouse()

  reaper.Undo_BeginBlock()

  if item then
    local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_end   = item_start + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local fade_len = item_end - fade_time
    if fade_len <= 0 then
      reaper.Undo_EndBlock("Add fade out to item under mouse cursor", -1)
      return
    end

    local grouped = PA_GetRelatedItemsAtSamePosition(item)
    apply_fadeout(item, fade_len)
    for _, gi in ipairs(grouped) do
      apply_fadeout(gi, fade_len)
    end
  else
    -- Souris sur du vide : retirer le fade out du premier item à gauche
    local left_item = get_first_item_to_left(track, fade_time)
    if not left_item or not is_item_visible(left_item) then
      reaper.Undo_EndBlock("Add fade out to item under mouse cursor", -1)
      return
    end

    local grouped = PA_GetRelatedItemsAtSamePosition(left_item)
    reaper.SetMediaItemInfo_Value(left_item, "D_FADEOUTLEN", 0)
    for _, gi in ipairs(grouped) do
      reaper.SetMediaItemInfo_Value(gi, "D_FADEOUTLEN", 0)
    end
  end

  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Add fade out to item under mouse cursor", -1)
end

main()

