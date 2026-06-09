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

  reaper.Undo_BeginBlock()
  if current_input == MIDI_INPUT_ALL then
    PA_SetTrackTemplateToInput(1)
    reaper.Undo_EndBlock("Set track template: Input 1", -1)
  else
    PA_SetTrackTemplateToMidi()
    reaper.Undo_EndBlock("Set track template: MIDI", -1)
  end
  reaper.UpdateArrange()
end

main()
