-- @description Record and snap edge to measure if music
-- @author lepierrealain
-- @version 2.0

local r = reaper

if not r.BR_SetItemEdges then
  r.ShowConsoleMsg("Ce script nécessite l'extension SWS.\n")
  return
end

-------------------------------------------------------
-- FILTRE : ancêtre "Music" (tous niveaux)
-------------------------------------------------------
local function IsDescendantOfMusic(item)
  local track = r.GetMediaItemTrack(item)
  local num_tracks = r.CountTracks(0)
  local depth = 0
  local parent_stack = {}
  for t = 0, num_tracks - 1 do
    local tr = r.GetTrack(0, t)
    if tr == track then
      for _, ancestor in ipairs(parent_stack) do
        local _, pname = r.GetTrackName(ancestor)
        if pname == "Music" then return true end
      end
      return false
    end
    local fd = r.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH")
    if fd >= 1 then
      depth = depth + 1
      parent_stack[depth] = tr
    elseif fd < 0 then
      depth = math.max(0, depth + fd)
      for d = depth + 1, #parent_stack do parent_stack[d] = nil end
    end
  end
  return false
end

-------------------------------------------------------
-- SNAP EDGE sur les items sélectionnés (MIDI, sous "Music")
-------------------------------------------------------
local function SnapSelectedItems()
  local sel_count = r.CountSelectedMediaItems(0)

  for i = sel_count - 1, 0, -1 do
    local item = r.GetSelectedMediaItem(0, i)
    local take = r.GetActiveTake(item)
    if not take or not r.TakeIsMIDI(take) or not IsDescendantOfMusic(item) then
      r.SetMediaItemSelected(item, false)
    end
  end

  local items_count = r.CountSelectedMediaItems(0)
  if items_count == 0 then return end

  for i = 0, items_count - 1 do
    local item = r.GetSelectedMediaItem(0, i)

    local it_start = r.GetMediaItemInfo_Value(item, 'D_POSITION')
    local it_len   = r.GetMediaItemInfo_Value(item, 'D_LENGTH')
    local it_end   = it_start + it_len

    local _, start_meas_idx = r.TimeMap2_timeToBeats(0, it_start)
    local new_start = r.TimeMap_GetMeasureInfo(0, start_meas_idx)

    local _, end_meas_idx = r.TimeMap2_timeToBeats(0, it_end)
    local end_meas_time = r.TimeMap_GetMeasureInfo(0, end_meas_idx)

    local new_end
    if it_end > (end_meas_time + 1e-7) then
      new_end = r.TimeMap_GetMeasureInfo(0, end_meas_idx + 1)
    else
      new_end = end_meas_time
    end

    if new_start ~= it_start or new_end ~= it_end then
      r.BR_SetItemEdges(item, new_start, new_end)
    end
  end

  r.UpdateArrange()
end

-------------------------------------------------------
-- WATCHER
-------------------------------------------------------
local armed = false  -- true une fois qu'on a vu le record actif au moins une fois

local function deferWatch()
  local play_state = r.GetPlayState()
  local is_recording = (play_state & 4) ~= 0

  if is_recording then
    armed = true
    r.defer(deferWatch)
    return
  end

  if armed then
    -- On a bien vu le record, et maintenant il est stoppé : on snape et on sort
    r.PreventUIRefresh(1)
    SnapSelectedItems()
    r.PreventUIRefresh(-1)
  end
  -- armed == false : record n'a jamais démarré, on sort sans rien faire
end

-------------------------------------------------------
-- MAIN
-------------------------------------------------------
r.Main_OnCommand(1013, 0)  -- Transport: Record
r.defer(deferWatch)
