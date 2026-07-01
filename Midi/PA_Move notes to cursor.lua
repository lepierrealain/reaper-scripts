-- @description Move selected MIDI notes so the first note starts at the mouse cursor (keeps pitches)
-- @author lepierrealain
-- @version 1.0

local lib_path = ({ reaper.get_action_context() })[2]:match("^(.+[\\/])")
local lib_root = lib_path .. ".." .. package.config:sub(1,1) .. "Libraries" .. package.config:sub(1,1)
dofile(lib_root .. "PA_lib_midi.lua")

local function nothing() end
local function bla() reaper.defer(nothing) end

local editor, take, mouse_ppq = PA_GetMidiEditorContext()
if not editor then bla() return end

-- Trouve le PPQ de début de la première note sélectionnée.
local _, note_count = reaper.MIDI_CountEvts(take)
local first_start_ppq = nil
for i = 0, note_count - 1 do
  local retval, sel, _, startppq = reaper.MIDI_GetNote(take, i)
  if retval and sel then
    if not first_start_ppq or startppq < first_start_ppq then
      first_start_ppq = startppq
    end
  end
end

if not first_start_ppq then bla() return end

-- Cible = position de la souris (PPQ), snappée à la grille si le snap MIDI est actif.
local target_ppq = PA_GetMidiTargetPPQ(editor, take, mouse_ppq)

local offset_ppq = target_ppq - first_start_ppq

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

-- Décale toutes les notes sélectionnées du même offset, sans changer la hauteur.
for i = 0, note_count - 1 do
  local retval, sel, muted, startppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
  if retval and sel then
    reaper.MIDI_SetNote(take, i, sel, muted,
      startppq + offset_ppq, endppq + offset_ppq,
      chan, pitch, vel, true)
  end
end

reaper.MIDI_Sort(take)
reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
reaper.Undo_EndBlock("Move selected MIDI notes to mouse cursor", -1)
