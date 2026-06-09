-- @description Insert new track in same folder as previous track
-- @author lepierrealain
-- @version 1.1

-- Inserts a new track after the last selected track, keeping it in the same folder.
-- If the selected track closes one or more folder levels (I_FOLDERDEPTH < 0),
-- the new track takes over that closing role so the folder structure stays intact.
-- If any ancestor folder is named "Music", auto record arm and beats timebase are applied.

local function getLastSelectedTrack()
  local sel_count = reaper.CountSelectedTracks(0)
  if sel_count == 0 then return nil, -1 end
  local last = reaper.GetSelectedTrack(0, sel_count - 1)
  local idx  = reaper.GetMediaTrackInfo_Value(last, "IP_TRACKNUMBER") - 1
  return last, idx
end

-- Returns true if any ancestor folder of the track at track_idx is named `name`.
-- Walks backwards through tracks, tracking folder depth to find true parents.
local function hasAncestorNamed(track_idx, name)
  local depth = 0
  for i = track_idx - 1, 0, -1 do
    local t  = reaper.GetTrack(0, i)
    local fd = reaper.GetMediaTrackInfo_Value(t, "I_FOLDERDEPTH")
    if fd >= 1 then
      -- This track opens a folder level; it is a parent of our track
      depth = depth - 1
      if depth < 0 then
        local _, tname = reaper.GetTrackName(t)
        if tname == name then return true end
        -- Keep walking up for grandparent folders
      end
    elseif fd < 0 then
      depth = depth - fd  -- fd is negative, so this adds to depth (closing levels)
    end
  end
  return false
end

local function applyMusicSettings(track)
  reaper.SetMediaTrackInfo_Value(track, "C_BEATATTACHMODE", 1)
  -- Toggle auto record arm (40736) only if currently off, track must be selected
  if reaper.GetToggleCommandState(40736) ~= 1 then
    reaper.Main_OnCommand(40736, 0)
  end
end

local function main()
  local ref_track, ref_idx = getLastSelectedTrack()

  local insert_idx
  if ref_track then
    insert_idx = ref_idx + 1
  else
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
      reaper.SetMediaTrackInfo_Value(new_track, "I_FOLDERDEPTH", 0)
    end
  end

  reaper.SetOnlyTrackSelected(new_track)

  if hasAncestorNamed(insert_idx, "Music") then
    applyMusicSettings(new_track)
  end

  reaper.Undo_EndBlock("Insert new track in same folder", -1)
  reaper.UpdateArrange()
  reaper.TrackList_AdjustWindows(false)
end

main()
