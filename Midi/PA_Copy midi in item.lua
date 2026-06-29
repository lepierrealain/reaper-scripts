-- @description Copy all MIDI info from selected item and paste into a new item on the track below
-- @author lepierrealain
-- @version 1.0

local lib_path = ({ reaper.get_action_context() })[2]:match("^(.+[\\/])")
local lib_root = lib_path .. ".." .. package.config:sub(1,1) .. "Libraries" .. package.config:sub(1,1)
dofile(lib_root .. "PA_lib_midi.lua")

local function nothing() end
local function bla() reaper.defer(nothing) end

-- Récupère l'item MIDI source : premier item sélectionné contenant une take MIDI.
local function GetSourceMidiItem()
  local count = reaper.CountSelectedMediaItems(0)
  for i = 0, count - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local take = reaper.GetActiveTake(item)
    if take and reaper.TakeIsMIDI(take) then
      return item, take
    end
  end
  return nil
end

local item, take = GetSourceMidiItem()
if not item then
  reaper.MB("Sélectionne un item MIDI.", "Copy MIDI in item", 0)
  bla()
  return
end

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

-- Position / longueur de l'item source.
local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
local src_track = reaper.GetMediaItem_Track(item)
local src_track_idx = reaper.GetMediaTrackInfo_Value(src_track, "IP_TRACKNUMBER") -- 1-based

-- Récupère toutes les infos MIDI brutes (notes, CC, pitchbend, sysex, text, etc.).
local midi = PA_CopyAllMidi(take)
if not midi then
  reaper.MB("Impossible de lire les données MIDI de l'item.", "Copy MIDI in item", 0)
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Copy MIDI in item (failed)", -1)
  return
end

-- Piste juste en dessous : si elle n'existe pas, on la crée.
local dest_track = reaper.GetTrack(0, src_track_idx) -- 0-based index = (1-based src) + 1 - 1
if not dest_track then
  reaper.InsertTrackAtIndex(src_track_idx, true)
  dest_track = reaper.GetTrack(0, src_track_idx)
end

-- Crée le nouvel item MIDI vide à la même position/longueur.
local new_item = reaper.CreateNewMIDIItemInProj(dest_track, item_pos, item_pos + item_len, false)
local new_take = reaper.GetActiveTake(new_item)

-- Colle toutes les infos MIDI récupérées dans le nouvel item.
PA_PasteAllMidi(new_take, midi)

-- Préserve position / longueur de la source pour conserver le timing exact.
reaper.SetMediaItemInfo_Value(new_item, "D_POSITION", item_pos)
reaper.SetMediaItemInfo_Value(new_item, "D_LENGTH", item_len)

-- Sélectionne uniquement le nouvel item.
reaper.SelectAllMediaItems(0, false)
reaper.SetMediaItemSelected(new_item, true)

reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
reaper.Undo_EndBlock("Copy MIDI in item", -1)
