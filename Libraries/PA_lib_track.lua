-- @description Track utility functions
-- @author lepierrealain
-- @version 1.0

-- I_RECINPUT: 4096 | channel (0=all) | (input << 5)
-- input 63 = all devices, channel 0 = all channels
local MIDI_INPUT_ALL = 4096 | 0 | (63 << 5)

-- Configure les pistes sélectionnées pour l'enregistrement audio (Input 1, arm, sans auto record arm).
function PA_SetTrackTemplateToInput(numInput)
  local count = reaper.CountSelectedTracks(0)
  if count == 0 then
    reaper.ShowMessageBox("No track selected.", "Set track to Audio", 0)
    return
  end

  for i = 0, count - 1 do
    local track = reaper.GetSelectedTrack(0, i)
    reaper.SetMediaTrackInfo_Value(track, "I_RECINPUT", numInput - 1)  -- 1-based → 0-based
    reaper.SetMediaTrackInfo_Value(track, "I_RECMODE", 0)
    reaper.SetMediaTrackInfo_Value(track, "I_RECMON", 0)  -- input monitoring off (audio)

    -- Désactiver l'auto record arm s'il est actif
    if reaper.GetToggleCommandState(40736) == 1 then
      reaper.Main_OnCommand(40736, 0)
    end
    
    reaper.SetMediaTrackInfo_Value(track, "I_RECARM", 1)
  end

end

-- Ouvre le FX dont le nom contient `search` sur la piste sélectionnée.
-- Si absent, l'ajoute via `plugin_name` (nom exact tel que retourné par EnumInstalledFX).
function PA_ShowOrAddFX(search, plugin_name)
  local track = reaper.GetSelectedTrack(0, 0)
  if not track then return end

  local fx_count = reaper.TrackFX_GetCount(track)
  for i = 0, fx_count - 1 do
    local _, name = reaper.TrackFX_GetFXName(track, i)
    if name:lower():find(search:lower(), 1, true) then
      reaper.TrackFX_Show(track, i, 3)
      return
    end
  end

  reaper.Undo_BeginBlock()
  local idx = reaper.TrackFX_AddByName(track, plugin_name, false, -1)
  reaper.Undo_EndBlock("Add " .. plugin_name, -1)
  if idx >= 0 then
    reaper.TrackFX_Show(track, idx, 3)
  end
end

-- Configure les pistes sélectionnées pour l'enregistrement MIDI (All MIDI, auto record arm).
function PA_SetTrackTemplateToMidi()
  local count = reaper.CountSelectedTracks(0)
  if count == 0 then
    reaper.ShowMessageBox("No track selected.", "Set track to MIDI", 0)
    return
  end

  for i = 0, count - 1 do
    local track = reaper.GetSelectedTrack(0, i)
    reaper.SetMediaTrackInfo_Value(track, "I_RECINPUT", MIDI_INPUT_ALL)
    reaper.SetMediaTrackInfo_Value(track, "I_RECMODE", 0)
    reaper.SetMediaTrackInfo_Value(track, "I_RECMON", 1)  -- input monitoring on (MIDI)
  end

  if reaper.GetToggleCommandState(40736) ~= 1 then
    reaper.Main_OnCommand(40736, 0)
  end
end
