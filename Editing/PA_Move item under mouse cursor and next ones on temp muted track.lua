-- @description Move item under mouse cursor and next ones on temp muted track
-- @author lepierrealain
-- @version 1.0

local lib_path = ({ reaper.get_action_context() })[2]:match("^(.+[\\/])")
local lib_root = lib_path .. ".." .. package.config:sub(1,1) .. "Libraries" .. package.config:sub(1,1)
dofile(lib_root .. "PA_lib_mouse.lua")

local TEMP_NAME = "Temp muted"

-- Retourne la piste "Temp muted" enfant juste en dessous de `track`, ou nil.
local function getTempTrackBelow(track)
  local idx = math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")) - 1  -- 1-based → 0-based
  local below = reaper.GetTrack(0, idx + 1)
  if not below then return nil end

  local _, name = reaper.GetSetMediaTrackInfo_String(below, "P_NAME", "", false)
  if name == TEMP_NAME and reaper.GetParentTrack(below) == track then
    return below
  end
  return nil
end

-- Crée la piste "Temp muted" mutée, enfant juste en dessous de `track`.
local function createTempTrackBelow(track)
  local idx = math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")) - 1
  local depth = math.floor(reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH"))

  reaper.InsertTrackAtIndex(idx + 1, true)
  local temp = reaper.GetTrack(0, idx + 1)
  reaper.GetSetMediaTrackInfo_String(temp, "P_NAME", TEMP_NAME, true)
  reaper.SetMediaTrackInfo_Value(temp, "B_MUTE", 1)

  -- Si `track` était déjà un folder (depth 1), la nouvelle piste insérée juste
  -- en dessous en devient automatiquement le premier enfant. Sinon, ouvrir le
  -- folder sur `track` et reporter sa fermeture (héritée) sur la nouvelle piste.
  if depth ~= 1 then
    reaper.SetMediaTrackInfo_Value(track, "I_FOLDERDEPTH", 1)
    reaper.SetMediaTrackInfo_Value(temp, "I_FOLDERDEPTH", depth - 1)
  end

  return temp
end

local function main()
  local item = PA_GetItemUnderMouse()
  if not item then return end

  local track = reaper.GetMediaItem_Track(item)
  local _, track_name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
  if track_name == TEMP_NAME then return end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local temp = getTempTrackBelow(track) or createTempTrackBelow(track)

  -- Copier la liste d'abord : MoveMediaItemToTrack décale les index de la piste source
  local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local items = {}
  for i = 0, reaper.CountTrackMediaItems(track) - 1 do
    local it = reaper.GetTrackMediaItem(track, i)
    if reaper.GetMediaItemInfo_Value(it, "D_POSITION") >= item_start then
      items[#items + 1] = it
    end
  end

  reaper.SelectAllMediaItems(0, false)
  for _, it in ipairs(items) do
    reaper.MoveMediaItemToTrack(it, temp)
    reaper.SetMediaItemSelected(it, true)
  end

  reaper.PreventUIRefresh(-1)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Move item under mouse cursor and next ones on temp muted track", -1)
end

main()
