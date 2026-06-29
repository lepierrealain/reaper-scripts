-- @description Remove silence under mouse cursor
-- @author lepierrealain
-- @version 1.0

local lib_path = ({ reaper.get_action_context() })[2]:match("^(.+[\\/])")
local lib_root = lib_path .. ".." .. package.config:sub(1,1) .. "Libraries" .. package.config:sub(1,1)
dofile(lib_root .. "PA_lib_mouse.lua")

local function in_lane(item, lane)
  return lane == nil
    or math.floor(reaper.GetMediaItemInfo_Value(item, "I_FIXEDLANE")) == lane
end

local function first_item_to_right(track, time, lane)
  local closest, closest_start = nil, math.huge
  for i = 0, reaper.CountTrackMediaItems(track) - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    if in_lane(item, lane) and start > time and start < closest_start then
      closest, closest_start = item, start
    end
  end
  return closest
end

local function left_item_end(track, time, lane)
  local best = nil
  for i = 0, reaper.CountTrackMediaItems(track) - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local item_end = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    if in_lane(item, lane) and item_end <= time and (not best or item_end > best) then
      best = item_end
    end
  end
  return best
end

local function ripple_enabled()
  return reaper.GetToggleCommandState(40310) == 1 -- ripple per-track
    or reaper.GetToggleCommandState(40311) == 1   -- ripple all tracks
end

local function main()
  local track, mouse_time = PA_GetMouseArrangeContext()
  if not track then return end

  local lane       = PA_GetHoveredFixedLane(track)
  local right_item = first_item_to_right(track, mouse_time, lane)
  local target     = left_item_end(track, mouse_time, lane)
  if not right_item or not target then return end

  local right_start = reaper.GetMediaItemInfo_Value(right_item, "D_POSITION")
  local delta       = target - right_start
  if delta == 0 then return end

  reaper.Undo_BeginBlock()
  if ripple_enabled() then
    -- Décale tous les items à droite (à partir de right_item) du même delta, sur la même lane.
    for i = 0, reaper.CountTrackMediaItems(track) - 1 do
      local item = reaper.GetTrackMediaItem(track, i)
      local pos  = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      if in_lane(item, lane) and pos >= right_start then
        reaper.SetMediaItemInfo_Value(item, "D_POSITION", pos + delta)
      end
    end
  else
    reaper.SetMediaItemInfo_Value(right_item, "D_POSITION", target)
  end
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Remove silence under mouse cursor", -1)
end

main()
