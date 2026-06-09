-- @description Set selected track to MIDI record template
-- @author lepierrealain
-- @version 1.1

local lib_path = ({ reaper.get_action_context() })[2]:match("^(.+[\\/])")
local lib_root = lib_path .. ".." .. package.config:sub(1,1) .. "Libraries" .. package.config:sub(1,1)
dofile(lib_root .. "PA_lib_track.lua")

local function main()
  reaper.Undo_BeginBlock()
  PA_SetTrackTemplateToMidi()
  reaper.Undo_EndBlock("Set track to MIDI template", -1)
  reaper.UpdateArrange()
end

main()
