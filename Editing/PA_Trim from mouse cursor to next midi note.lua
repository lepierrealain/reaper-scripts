-- @description Trim from mouse cursor to next midi note
-- @author lepierrealain
-- @version 1.0

local lib_path = ({ reaper.get_action_context() })[2]:match("^(.+[\\/])")
local lib_root = lib_path .. ".." .. package.config:sub(1,1) .. "Libraries" .. package.config:sub(1,1)
dofile(lib_root .. "PA_lib_mouse.lua")

-- Retourne le temps projet de départ de la première note dont le start est
-- strictement après after_time, ou nil si aucune.
local function get_next_note_start_time(take, after_time)
  local _, note_count = reaper.MIDI_CountEvts(take)
  local after_ppq = reaper.MIDI_GetPPQPosFromProjTime(take, after_time)
  local best_start_ppq = math.huge
  for i = 0, note_count - 1 do
    local _, _, _, startppq = reaper.MIDI_GetNote(take, i)
    if startppq > after_ppq and startppq < best_start_ppq then
      best_start_ppq = startppq
    end
  end
  if best_start_ppq == math.huge then return nil end
  return reaper.MIDI_GetProjTimeFromPPQPos(take, best_start_ppq)
end

-- Retourne le premier item MIDI dont le début est après time, sur la track (lane optionnelle).
local function get_first_midi_item_to_right(track, time, lane)
  local num_items = reaper.CountTrackMediaItems(track)
  local closest, closest_start = nil, math.huge
  for i = 0, num_items - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    if lane == nil or math.floor(reaper.GetMediaItemInfo_Value(item, "I_FIXEDLANE")) == lane then
      local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      if item_start > time and item_start < closest_start then
        local take = reaper.GetActiveTake(item)
        if take and reaper.TakeIsMIDI(take) then
          closest = item
          closest_start = item_start
        end
      end
    end
  end
  return closest
end

-- Trim le bord gauche de target_item jusqu'à note_start (supprime le contenu
-- cut_time -> note_start), puis ramène l'item à cut_time.
local function trim_and_pull(target_item, note_start, cut_time)
  local take        = reaper.GetActiveTake(target_item)
  local item_start  = reaper.GetMediaItemInfo_Value(target_item, "D_POSITION")
  local item_len    = reaper.GetMediaItemInfo_Value(target_item, "D_LENGTH")
  local trim_delta  = item_start - note_start -- négatif (on raccourcit par la gauche)

  reaper.SetMediaItemInfo_Value(target_item, "D_POSITION", note_start)
  reaper.SetMediaItemInfo_Value(target_item, "D_LENGTH",   item_len + trim_delta)
  if take then
    local playrate   = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
    local start_offs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
    reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", start_offs - trim_delta * playrate)
  end

  reaper.SetMediaItemInfo_Value(target_item, "D_POSITION", cut_time)
end

local function main()
  local snap_enabled = reaper.GetToggleCommandState(1157) == 1

  local track, mouse_time = PA_GetMouseArrangeContext()
  if not track or not mouse_time then return end

  local cut_time = snap_enabled and reaper.SnapToGrid(0, mouse_time) or mouse_time

  local item = PA_GetItemUnderMouse()

  if item then
    -- Souris sur un item MIDI.
    local take = reaper.GetActiveTake(item)
    if not take or not reaper.TakeIsMIDI(take) then return end

    -- Prochaine note qui démarre strictement après la souris.
    local note_start = get_next_note_start_time(take, cut_time)
    if not note_start or note_start - cut_time <= 0.0001 then return end

    reaper.Undo_BeginBlock()

    -- Splitter à la souris : la partie gauche reste intacte, on ne travaille
    -- que sur la partie droite.
    local right_item = reaper.SplitMediaItem(item, cut_time)
    if not right_item then
      reaper.Undo_EndBlock("Trim from mouse cursor to next midi note", -1)
      return
    end
    trim_and_pull(right_item, note_start, cut_time)
  else
    -- Souris sur du vide : premier item MIDI à droite sur la track.
    local right_item = get_first_midi_item_to_right(track, cut_time, PA_GetHoveredFixedLane(track))
    if not right_item then return end

    local take = reaper.GetActiveTake(right_item)
    local note_start = get_next_note_start_time(take, cut_time)
    if not note_start or note_start - cut_time <= 0.0001 then return end

    reaper.Undo_BeginBlock()

    -- Pas de split : l'item entier est à droite de la souris, on le ramène en entier.
    trim_and_pull(right_item, note_start, cut_time)
  end

  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Trim from mouse cursor to next midi note", -1)
end

main()
