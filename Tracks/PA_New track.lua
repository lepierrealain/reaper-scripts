-- @description Insert new track in same folder as previous track
-- @author lepierrealain
-- @version 1.0

-- Inserts a new track after the last selected track, keeping it in the same folder.
-- If the selected track closes one or more folder levels (I_FOLDERDEPTH < 0),
-- the new track takes over that closing role so the folder structure stays intact.

local function getLastSelectedTrack()
  local sel_count = reaper.CountSelectedTracks(0)
  if sel_count == 0 then return nil, -1 end
  local last = reaper.GetSelectedTrack(0, sel_count - 1)
  local idx  = reaper.GetMediaTrackInfo_Value(last, "IP_TRACKNUMBER") - 1
  return last, idx
end

local function main()
  local ref_track, ref_idx = getLastSelectedTrack()

  local insert_idx
  if ref_track then
    insert_idx = ref_idx + 1
  else
    -- Aucune piste sélectionnée : insérer à la fin
    insert_idx = reaper.CountTracks(0)
  end

  reaper.Undo_BeginBlock()

  reaper.InsertTrackAtIndex(insert_idx, true)
  local new_track = reaper.GetTrack(0, insert_idx)

  if ref_track then
    local ref_fd = reaper.GetMediaTrackInfo_Value(ref_track, "I_FOLDERDEPTH")

    if ref_fd < 0 then
      -- La piste de référence ferme des niveaux : la nouvelle hérite de ce rôle,
      -- et la piste de référence redevient neutre (depth 0).
      reaper.SetMediaTrackInfo_Value(ref_track, "I_FOLDERDEPTH", 0)
      reaper.SetMediaTrackInfo_Value(new_track,  "I_FOLDERDEPTH", ref_fd)
    else
      -- Piste normale ou début de dossier : nouvelle piste au même niveau (depth 0)
      reaper.SetMediaTrackInfo_Value(new_track, "I_FOLDERDEPTH", 0)
    end
  end

  -- Sélectionner uniquement la nouvelle piste
  reaper.SetOnlyTrackSelected(new_track)

  reaper.Undo_EndBlock("Insert new track in same folder", -1)
  reaper.UpdateArrange()
  reaper.TrackList_AdjustWindows(false)
end

main()
