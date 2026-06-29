-- @description Select all items on track under mouse cursor (defer)
-- @author lepierrealain
-- @version 1.0

local lib_path = ({ reaper.get_action_context() })[2]:match("^(.+[\\/])")
local lib_root = lib_path .. ".." .. package.config:sub(1,1) .. "Libraries" .. package.config:sub(1,1)
dofile(lib_root .. "PA_lib_mouse.lua")

local target_item = nil
local has_started = false  -- passe à true dès que le playback a démarré

local function is_playing()
  local state = reaper.GetPlayState()
  return state & 1 == 1 or state & 4 == 1
end

-- Premier item de la track (lane respectée) commençant après `time`, ou nil.
local function get_next_item(track, time, lane)
  local closest, closest_start = nil, math.huge
  for i = 0, reaper.CountTrackMediaItems(track) - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    if lane == nil or math.floor(reaper.GetMediaItemInfo_Value(item, "I_FIXEDLANE")) == lane then
      local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      if item_start > time and item_start < closest_start then
        closest, closest_start = item, item_start
      end
    end
  end
  return closest
end

local function select_only_target()
  reaper.SelectAllMediaItems(0, false)
  if target_item and reaper.ValidatePtr(target_item, "MediaItem*") then
    reaper.SetMediaItemSelected(target_item, true)
  end
  reaper.UpdateArrange()
end

local function loop()
  if not has_started then
    -- On attend que le playback démarre
    if is_playing() then has_started = true end
    reaper.defer(loop)
    return
  end

  -- Le playback a démarré : on attend qu'il s'arrête
  if is_playing() then
    reaper.defer(loop)
    return
  end

  select_only_target()
  reaper.Undo_EndBlock("Select all items on track under mouse cursor (defer)", -1)
end

local function main()
  local track = select(1, PA_GetMouseArrangeContext())
  if not track then return end

  local lane = PA_GetHoveredFixedLane(track)
  local _, mouse_time = PA_GetMouseArrangeContext()
  target_item = PA_GetItemUnderMouse()
  -- Aucun item sous la souris : on cible le suivant sur la track sous le curseur.
  if not target_item and mouse_time then
    target_item = get_next_item(track, mouse_time, lane)
  end

  reaper.Undo_BeginBlock()
  reaper.SelectAllMediaItems(0, false)
  for i = 0, reaper.CountTrackMediaItems(track) - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    if lane == nil or math.floor(reaper.GetMediaItemInfo_Value(item, "I_FIXEDLANE")) == lane then
      reaper.SetMediaItemSelected(item, true)
    end
  end
  reaper.UpdateArrange()

  -- Le script est lancé playback arrêté : on attend qu'il démarre puis s'arrête.
  reaper.defer(loop)
end

main()
