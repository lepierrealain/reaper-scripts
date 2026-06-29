-- @description Trim left of item under mouse cursor
-- @author lepierrealain
-- @version 1.0

local lib_path = ({ reaper.get_action_context() })[2]:match("^(.+[\\/])")
local lib_root = lib_path .. ".." .. package.config:sub(1,1) .. "Libraries" .. package.config:sub(1,1)
dofile(lib_root .. "PA_lib_mouse.lua")
dofile(lib_root .. "PA_lib_item.lua")

local function is_item_visible(item)
  local view_start, view_end = reaper.GetSet_ArrangeView2(0, false, 0, 0)
  local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_end   = item_start + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  return item_start < view_end and item_end > view_start
end

local function get_first_item_to_right(track, time, lane)
  local num_items = reaper.CountTrackMediaItems(track)
  local closest, closest_start = nil, math.huge
  for i = 0, num_items - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    if lane == nil or math.floor(reaper.GetMediaItemInfo_Value(item, "I_FIXEDLANE")) == lane then
      local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      if item_start > time and item_start < closest_start then
        closest = item
        closest_start = item_start
      end
    end
  end
  return closest
end

local function main()
  local snap_enabled = reaper.GetToggleCommandState(1157) == 1
  local track, mouse_time = PA_GetMouseArrangeContext()
  if not track then return end

  local split_time = snap_enabled and reaper.SnapToGrid(0, mouse_time) or mouse_time

  local item = PA_GetItemUnderMouse()

  reaper.Undo_BeginBlock()

  if item then
    -- Souris sur un item : trimmer le bord gauche
    local grouped = PA_GetRelatedItemsAtSamePosition(item)
    local fadein = reaper.GetMediaItemInfo_Value(item, "D_FADEINLEN")
    -- PA_TrimItemLeft peut recréer l'item (dé-pool MIDI) ; il préserve alors le fadein
    -- lui-même, donc on ne le réécrit que si l'item n'a pas changé.
    local result = PA_TrimItemLeft(item, split_time)
    if result == item and fadein > 0 then
      reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", fadein)
    end
    for _, gi in ipairs(grouped) do
      local gi_fadein = reaper.GetMediaItemInfo_Value(gi, "D_FADEINLEN")
      local gi_result = PA_TrimItemLeft(gi, split_time)
      if gi_result == gi and gi_fadein > 0 then
        reaper.SetMediaItemInfo_Value(gi, "D_FADEINLEN", gi_fadein)
      end
    end
  else
    -- Souris sur du vide : étendre le premier item à droite par la gauche
    local right_item = get_first_item_to_right(track, split_time, PA_GetHoveredFixedLane(track))
    if not right_item then
      reaper.Undo_EndBlock("Trim left of item under mouse cursor", -1)
      return
    end
    if not is_item_visible(right_item) then
      reaper.Undo_EndBlock("Trim left of item under mouse cursor", -1)
      return
    end
    -- Ne rien faire si split_time est déjà le début exact de l'item
    local right_start = reaper.GetMediaItemInfo_Value(right_item, "D_POSITION")
    if math.abs(right_start - split_time) < 0.0001 then
      reaper.Undo_EndBlock("Trim left of item under mouse cursor", -1)
      return
    end

    local grouped = PA_GetRelatedItemsAtSamePosition(right_item)
    PA_TrimItemLeft(right_item, split_time)
    for _, gi in ipairs(grouped) do
      PA_TrimItemLeft(gi, split_time)
    end
  end

  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Trim left of item under mouse cursor", -1)
end

main()
