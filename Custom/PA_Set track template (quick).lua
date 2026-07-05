-- @description Toggle track template between MIDI and Input 1
-- @author lepierrealain
-- @version 1.0

local lib_path = ({ reaper.get_action_context() })[2]:match("^(.+[\\/])")
local lib_root = lib_path .. ".." .. package.config:sub(1,1) .. "Libraries" .. package.config:sub(1,1)
dofile(lib_root .. "PA_lib_track.lua")

local MIDI_INPUT_ALL = 4096 | 0 | (63 << 5)

local function main()
  local track = reaper.GetSelectedTrack(0, 0)
  if not track then return end

  local current_input = reaper.GetMediaTrackInfo_Value(track, "I_RECINPUT")
  local armed = reaper.GetMediaTrackInfo_Value(track, "I_RECARM") == 1
  local has_instrument = reaper.TrackFX_GetInstrument(track) >= 0

  -- Cycle : MIDI → Input armé → Input désarmé → MIDI
  -- Sans instrument (VSTi/CLAPi), on ne passe jamais en MIDI.
  -- L'input audio en cours est conservé (Input 1 par défaut).
  reaper.Undo_BeginBlock()
  if current_input == MIDI_INPUT_ALL then
    PA_SetTrackTemplateToInput()
    reaper.Undo_EndBlock("Set track template: Input", -1)
  elseif armed then
    PA_SetTrackTemplateToInputIdle()
    reaper.Undo_EndBlock("Set track template: Input (idle)", -1)
  elseif has_instrument then
    PA_SetTrackTemplateToMidi()
    reaper.Undo_EndBlock("Set track template: MIDI", -1)
  else
    PA_SetTrackTemplateToInput()
    reaper.Undo_EndBlock("Set track template: Input", -1)
  end
  reaper.UpdateArrange()
end

main()
