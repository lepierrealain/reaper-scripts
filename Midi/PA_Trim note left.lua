-- @description Trim left of MIDI note under mouse cursor
-- @author lepierrealain
-- @version 1.0

local lib_path = ({ reaper.get_action_context() })[2]:match("^(.+[\\/])")
local lib_root = lib_path .. ".." .. package.config:sub(1,1) .. "Libraries" .. package.config:sub(1,1)
dofile(lib_root .. "PA_lib_midi.lua")

local function nothing() end
local function bla() reaper.defer(nothing) end

local editor, take, mouse_ppq, noteRow = PA_GetMidiEditorContext()
if not editor then bla() return end

local target_ppq = PA_GetMidiTargetPPQ(editor, take, mouse_ppq)

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

if PA_CountSelectedMidiNotes(take) > 1 then
  PA_TrimSelectedNotesLeft(take, target_ppq)
else
  PA_TrimNoteLeftUnderMouse(take, mouse_ppq, target_ppq, noteRow)
end

reaper.MIDI_Sort(take)
reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
reaper.Undo_EndBlock("Trim left of MIDI note under mouse cursor", -1)
