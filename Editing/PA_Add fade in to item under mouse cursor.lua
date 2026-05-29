-- @description Add fade in to item under mouse cursor
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

local function get_first_item_to_right(track, time)
  local num_items = reaper.CountTrackMediaItems(track)
  local closest, closest_start = nil, math.huge
  for i = 0, num_items - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    if item_start > time and item_start < closest_start then
      closest = item
      closest_start = item_start
    end
  end
  return closest
end

local function apply_fadein(item, fade_len)
  local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", math.min(fade_len, item_len))
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
    local fade_len = fade_time - item_start
    if fade_len <= 0 then
      reaper.Undo_EndBlock("Add fade in to item under mouse cursor", -1)
      return
    end

    local grouped = PA_GetRelatedItemsAtSamePosition(item)
    apply_fadein(item, fade_len)
    for _, gi in ipairs(grouped) do
      apply_fadein(gi, fade_len)
    end
  else
    -- Souris sur du vide : retirer le fade in du premier item à droite
    local right_item = get_first_item_to_right(track, fade_time)
    if not right_item or not is_item_visible(right_item) then
      reaper.Undo_EndBlock("Add fade in to item under mouse cursor", -1)
      return
    end

    local grouped = PA_GetRelatedItemsAtSamePosition(right_item)
    reaper.SetMediaItemInfo_Value(right_item, "D_FADEINLEN", 0)
    for _, gi in ipairs(grouped) do
      reaper.SetMediaItemInfo_Value(gi, "D_FADEINLEN", 0)
    end
  end

  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Add fade in to item under mouse cursor", -1)
end

main()
