-- @description Trim right of item under mouse cursor
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

local function main()
  local snap_enabled = reaper.GetToggleCommandState(1157) == 1
  local track, mouse_time = PA_GetMouseArrangeContext()
  if not track then return end

  local split_time = snap_enabled and reaper.SnapToGrid(0, mouse_time) or mouse_time

  local item = PA_GetItemUnderMouse()

  reaper.Undo_BeginBlock()

  if item then
    -- Souris sur un item : couper et supprimer la partie droite
    -- SplitMediaItem retourne la partie droite ; l'original devient la partie gauche
    local grouped = PA_GetRelatedItemsAtSamePosition(item)
    local fadeout = reaper.GetMediaItemInfo_Value(item, "D_FADEOUTLEN")
    local right_part = reaper.SplitMediaItem(item, split_time)
    if right_part then
      reaper.DeleteTrackMediaItem(track, right_part)
      if fadeout > 0 then
        local new_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", math.min(fadeout, new_len))
      end
      for _, gi in ipairs(grouped) do
        local gi_track = reaper.GetMediaItemTrack(gi)
        local gi_fadeout = reaper.GetMediaItemInfo_Value(gi, "D_FADEOUTLEN")
        local gi_right = reaper.SplitMediaItem(gi, split_time)
        if gi_right then
          reaper.DeleteTrackMediaItem(gi_track, gi_right)
          if gi_fadeout > 0 then
            local gi_new_len = reaper.GetMediaItemInfo_Value(gi, "D_LENGTH")
            reaper.SetMediaItemInfo_Value(gi, "D_FADEOUTLEN", math.min(gi_fadeout, gi_new_len))
          end
        end
      end
    end
  else
    -- Souris sur du vide : étendre le premier item à gauche par la droite
    local left_item = get_first_item_to_left(track, split_time)
    if not left_item then
      reaper.Undo_EndBlock("Trim right of item under mouse cursor", -1)
      return
    end
    if not is_item_visible(left_item) then
      reaper.Undo_EndBlock("Trim right of item under mouse cursor", -1)
      return
    end
    -- Ne rien faire si split_time est déjà la fin exacte de l'item
    local left_end = reaper.GetMediaItemInfo_Value(left_item, "D_POSITION") + reaper.GetMediaItemInfo_Value(left_item, "D_LENGTH")
    if math.abs(left_end - split_time) < 0.0001 then
      reaper.Undo_EndBlock("Trim right of item under mouse cursor", -1)
      return
    end

    local grouped = PA_GetRelatedItemsAtSamePosition(left_item)
    PA_TrimItemRight(left_item, split_time)
    for _, gi in ipairs(grouped) do
      PA_TrimItemRight(gi, split_time)
    end
  end

  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Trim right of item under mouse cursor", -1)
end

main()
