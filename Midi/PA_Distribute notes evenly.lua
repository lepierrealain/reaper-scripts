-- @description Distribute selected MIDI notes evenly in time (even start spacing, keeps lengths and pitches)
-- @author lepierrealain
-- @version 1.0

local lib_path = ({ reaper.get_action_context() })[2]:match("^(.+[\\/])")
local lib_root = lib_path .. ".." .. package.config:sub(1,1) .. "Libraries" .. package.config:sub(1,1)
dofile(lib_root .. "PA_lib_midi.lua")

local function nothing() end
local function bla() reaper.defer(nothing) end

-- On n'a pas besoin du contexte souris ici : l'action agit sur les notes sélectionnées.
-- Il suffit d'un éditeur MIDI actif avec un take valide.
local editor = reaper.MIDIEditor_GetActive()
if not editor then bla() return end
local take = reaper.MIDIEditor_GetTake(editor)
if not take then bla() return end

-- Collecte les index des notes sélectionnées avec leur PPQ de début.
local _, note_count = reaper.MIDI_CountEvts(take)
local selected = {}
for i = 0, note_count - 1 do
  local retval, sel, _, startppq = reaper.MIDI_GetNote(take, i)
  if retval and sel then
    selected[#selected + 1] = { idx = i, startppq = startppq }
  end
end

-- Il faut au moins 3 notes : les extrêmes restent en place, on répartit les intermédiaires.
if #selected < 3 then bla() return end

-- Trie par position de début pour raisonner sur l'ordre temporel réel.
table.sort(selected, function(a, b) return a.startppq < b.startppq end)

local first_ppq = selected[1].startppq
local last_ppq  = selected[#selected].startppq
local span      = last_ppq - first_ppq
if span <= 0 then bla() return end

local step = span / (#selected - 1)

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

-- Repositionne chaque note à un début équidistant, en conservant sa longueur et sa hauteur.
for n = 1, #selected do
  local i = selected[n].idx
  local retval, sel, muted, startppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
  if retval then
    local new_start = math.floor(first_ppq + step * (n - 1) + 0.5)
    local length    = endppq - startppq
    reaper.MIDI_SetNote(take, i, sel, muted,
      new_start, new_start + length,
      chan, pitch, vel, true)
  end
end

reaper.MIDI_Sort(take)
reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
reaper.Undo_EndBlock("Distribute selected MIDI notes evenly", -1)
