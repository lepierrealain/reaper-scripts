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
-- Renvoie les bornes (temps projet) du contenu MIDI : premier et dernier
-- event (notes, CC, sysex...). Renvoie nil si l'item est vide.
-------------------------------------------------------
local function GetMidiContentBounds(item, take)
  local _, note_cnt, cc_cnt, syx_cnt = r.MIDI_CountEvts(take)

  local first_ppq = math.huge
  local last_ppq  = -math.huge

  -- Notes (start + end pris en compte)
  for n = 0, note_cnt - 1 do
    local retval, _, _, start_ppq, end_ppq = r.MIDI_GetNote(take, n)
    if retval then
      if start_ppq < first_ppq then first_ppq = start_ppq end
      if end_ppq > last_ppq then last_ppq = end_ppq end
    end
  end

  -- CC
  for n = 0, cc_cnt - 1 do
    local retval, _, _, ppq = r.MIDI_GetCC(take, n)
    if retval then
      if ppq < first_ppq then first_ppq = ppq end
      if ppq > last_ppq then last_ppq = ppq end
    end
  end

  -- Sysex / text / meta
  for n = 0, syx_cnt - 1 do
    local retval, _, _, ppq = r.MIDI_GetTextSysexEvt(take, n)
    if retval then
      if ppq < first_ppq then first_ppq = ppq end
      if ppq > last_ppq then last_ppq = ppq end
    end
  end

  if first_ppq == math.huge or last_ppq == -math.huge then return nil end

  local first_time = r.MIDI_GetProjTimeFromPPQPos(take, first_ppq)
  local last_time  = r.MIDI_GetProjTimeFromPPQPos(take, last_ppq)
  return first_time, last_time
end

-------------------------------------------------------
-- TRIM gauche/droite sur tous les events MIDI (notes, CC, sysex...)
-------------------------------------------------------
local function TrimToFirstMidiNote(item, take)
  local first_time, last_time = GetMidiContentBounds(item, take)
  if not first_time then return end

  local it_start   = r.GetMediaItemInfo_Value(item, 'D_POSITION')
  local it_end     = it_start + r.GetMediaItemInfo_Value(item, 'D_LENGTH')

  local new_start = (first_time > it_start and first_time < it_end) and first_time or it_start
  local new_end   = (last_time  < it_end   and last_time  > it_start) and last_time  or it_end

  if new_start < new_end and (new_start ~= it_start or new_end ~= it_end) then
    r.BR_SetItemEdges(item, new_start, new_end)
  end
end

-------------------------------------------------------
-- SNAP EDGE sur les items sélectionnés (MIDI, sous "Music")
-------------------------------------------------------
local function SnapSelectedItems()
  local sel_count = r.CountSelectedMediaItems(0)

  for i = sel_count - 1, 0, -1 do
    local item = r.GetSelectedMediaItem(0, i)
    local take = r.GetActiveTake(item)
    if not take or not r.TakeIsMIDI(take) then
      r.SetMediaItemSelected(item, false)
    end
  end

  local items_count = r.CountSelectedMediaItems(0)
  if items_count == 0 then return end

  for i = 0, items_count - 1 do
    local item = r.GetSelectedMediaItem(0, i)
    local take = r.GetActiveTake(item)

    if IsDescendantOfMusic(item) then
      local it_start = r.GetMediaItemInfo_Value(item, 'D_POSITION')
      local it_len   = r.GetMediaItemInfo_Value(item, 'D_LENGTH')
      local it_end   = it_start + it_len

      -- On snape sur les bornes du contenu MIDI (et non sur les bords bruts
      -- de l'item) pour ne pas conserver de mesures blanches en début/fin.
      local content_start, content_end = GetMidiContentBounds(item, take)
      local snap_start = it_start
      local snap_end   = it_end
      if content_start then
        if content_start > it_start and content_start < it_end then snap_start = content_start end
        if content_end   < it_end   and content_end   > it_start then snap_end   = content_end   end
      end

      local _, start_meas_idx = r.TimeMap2_timeToBeats(0, snap_start)
      local meas_start = r.TimeMap_GetMeasureInfo(0, start_meas_idx)
      local next_meas_start = r.TimeMap_GetMeasureInfo(0, start_meas_idx + 1)
      local meas_len = next_meas_start - meas_start

      -- Par défaut on snape au début de la mesure qui contient le contenu.
      -- Exception : si le contenu commence dans les 5% finaux de sa mesure
      -- (mesure quasi vide), on snape plutôt au début de la mesure suivante.
      local new_start
      if meas_len > 0 and (snap_start - meas_start) > (meas_len * 0.95) then
        new_start = next_meas_start
      else
        new_start = meas_start
      end

      local _, end_meas_idx = r.TimeMap2_timeToBeats(0, snap_end)
      local end_meas_time = r.TimeMap_GetMeasureInfo(0, end_meas_idx)

      local new_end
      if snap_end > (end_meas_time + 1e-7) then
        new_end = r.TimeMap_GetMeasureInfo(0, end_meas_idx + 1)
      else
        new_end = end_meas_time
      end

      -- Garde-fou : on ne doit jamais produire un item vide ou inversé
      -- (ex. tout le contenu tient dans les 5% restants d'une seule mesure).
      if new_start >= new_end then
        new_start = meas_start
      end

      if new_start ~= it_start or new_end ~= it_end then
        r.BR_SetItemEdges(item, new_start, new_end)
      end
    else
      TrimToFirstMidiNote(item, take)
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
    r.Undo_BeginBlock()
    SnapSelectedItems()
    r.Undo_EndBlock("Record and snap edge to measure (Music)", -1)
    r.PreventUIRefresh(-1)
  end
  -- armed == false : record n'a jamais démarré, on sort sans rien faire
end

-------------------------------------------------------
-- MAIN
-------------------------------------------------------
r.Main_OnCommand(1013, 0)  -- Transport: Record
r.defer(deferWatch)
