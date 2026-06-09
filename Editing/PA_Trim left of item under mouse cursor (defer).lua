-- @description Trim left of item under mouse cursor (defer)
-- @author lepierrealain
-- @version 1.0

local lib_path = ({ reaper.get_action_context() })[2]:match("^(.+[\\/])")
local lib_root = lib_path .. ".." .. package.config:sub(1,1) .. "Libraries" .. package.config:sub(1,1)
dofile(lib_root .. "PA_lib_mouse.lua")
dofile(lib_root .. "PA_lib_item.lua")

local target_item     = nil
local target_grouped  = nil
local prev_split_time = nil
local last_was_stretch = false
local STRETCH_EPSILON  = 0.0001  -- secondes

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

-- Retourne "item", "empty" ou false
local function resolve_target()
  local snap_enabled = reaper.GetToggleCommandState(1157) == 1
  local track, mouse_time = PA_GetMouseArrangeContext()
  if not track then return false end

  local split_time = snap_enabled and reaper.SnapToGrid(0, mouse_time) or mouse_time
  local item = PA_GetItemUnderMouse()

  if item then
    target_item    = item
    target_grouped = PA_GetRelatedItemsAtSamePosition(item)
    return "item", split_time
  end

  -- Cas bord gauche exact : la souris est pile sur le début d'un item
  local num_items = reaper.CountTrackMediaItems(track)
  for i = 0, num_items - 1 do
    local candidate = reaper.GetTrackMediaItem(track, i)
    local candidate_start = reaper.GetMediaItemInfo_Value(candidate, "D_POSITION")
    if math.abs(candidate_start - split_time) < 0.0001 then
      target_item    = candidate
      target_grouped = PA_GetRelatedItemsAtSamePosition(candidate)
      return "item", split_time
    end
  end

  local right_item = get_first_item_to_right(track, split_time)
  if not right_item or not is_item_visible(right_item) then return false end
  target_item    = right_item
  target_grouped = PA_GetRelatedItemsAtSamePosition(right_item)
  return "empty", split_time
end

local function do_trim(split_time)
  if split_time == prev_split_time then return end
  prev_split_time = split_time

  if not reaper.ValidatePtr(target_item, "MediaItem*") then return end

  local item_start = reaper.GetMediaItemInfo_Value(target_item, "D_POSITION")

  if split_time <= item_start then
    PA_TrimItemLeft(target_item, split_time)
    for _, gi in ipairs(target_grouped) do
      if reaper.ValidatePtr(gi, "MediaItem*") then
        PA_TrimItemLeft(gi, split_time)
      end
    end
    last_was_stretch = true
  else
    last_was_stretch = false
    local fadein     = reaper.GetMediaItemInfo_Value(target_item, "D_FADEINLEN")
    local item_track = reaper.GetMediaItemTrack(target_item)
    local right_part = reaper.SplitMediaItem(target_item, split_time)
    if right_part then
      reaper.DeleteTrackMediaItem(item_track, target_item)
      if fadein > 0 then
        reaper.SetMediaItemInfo_Value(right_part, "D_FADEINLEN", fadein)
      end
      target_item = right_part
      for idx, gi in ipairs(target_grouped) do
        if reaper.ValidatePtr(gi, "MediaItem*") then
          local gi_track  = reaper.GetMediaItemTrack(gi)
          local gi_fadein = reaper.GetMediaItemInfo_Value(gi, "D_FADEINLEN")
          local gi_right  = reaper.SplitMediaItem(gi, split_time)
          if gi_right then
            reaper.DeleteTrackMediaItem(gi_track, gi)
            if gi_fadein > 0 then
              reaper.SetMediaItemInfo_Value(gi_right, "D_FADEINLEN", gi_fadein)
            end
            target_grouped[idx] = gi_right
          end
        end
      end
    end
  end

  reaper.UpdateArrange()
end

local function fix_midi_stretch()
  if not last_was_stretch then return end
  if not reaper.ValidatePtr(target_item, "MediaItem*") then return end

  local item_start = reaper.GetMediaItemInfo_Value(target_item, "D_POSITION")
  local target_pos = item_start

  PA_TrimItemLeft(target_item, item_start - STRETCH_EPSILON)
  for _, gi in ipairs(target_grouped) do
    if reaper.ValidatePtr(gi, "MediaItem*") then
      PA_TrimItemLeft(gi, item_start - STRETCH_EPSILON)
    end
  end

  local fadein     = reaper.GetMediaItemInfo_Value(target_item, "D_FADEINLEN")
  local item_track = reaper.GetMediaItemTrack(target_item)
  local right_part = reaper.SplitMediaItem(target_item, target_pos)
  if right_part then
    reaper.DeleteTrackMediaItem(item_track, target_item)
    if fadein > 0 then
      reaper.SetMediaItemInfo_Value(right_part, "D_FADEINLEN", fadein)
    end
    for idx, gi in ipairs(target_grouped) do
      if reaper.ValidatePtr(gi, "MediaItem*") then
        local gi_track  = reaper.GetMediaItemTrack(gi)
        local gi_fadein = reaper.GetMediaItemInfo_Value(gi, "D_FADEINLEN")
        local gi_right  = reaper.SplitMediaItem(gi, target_pos)
        if gi_right then
          reaper.DeleteTrackMediaItem(gi_track, gi)
          if gi_fadein > 0 then
            reaper.SetMediaItemInfo_Value(gi_right, "D_FADEINLEN", gi_fadein)
          end
          target_grouped[idx] = gi_right
        end
      end
    end
  end

  reaper.UpdateArrange()
end

local function loop()
  -- Stop on left mouse click
  if reaper.JS_Mouse_GetState(1) & 1 == 1 then
    fix_midi_stretch()
    reaper.Undo_EndBlock("Trim left of item under mouse cursor", -1)
    return
  end

  local snap_enabled = reaper.GetToggleCommandState(1157) == 1
  local track, mouse_time = PA_GetMouseArrangeContext()
  if track and mouse_time then
    local split_time = snap_enabled and reaper.SnapToGrid(0, mouse_time) or mouse_time
    do_trim(split_time)
  end

  reaper.defer(loop)
end

if not reaper.JS_Mouse_GetState then
  reaper.MB("js_ReaScriptAPI is required for this script.", "Error", 0)
  return
end

local context, split_time = resolve_target()
if context == "item" then
  reaper.Undo_BeginBlock()
  do_trim(split_time)
  reaper.Undo_EndBlock("Trim left of item under mouse cursor", -1)
elseif context == "empty" then
  reaper.Undo_BeginBlock()
  reaper.defer(loop)
end
