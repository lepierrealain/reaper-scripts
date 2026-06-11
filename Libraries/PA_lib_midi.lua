-- @description MIDI utility functions
-- @author lepierrealain
-- @version 1.0

-- Retourne editor, take, mouse_ppq, noteRow depuis le contexte souris dans l'éditeur MIDI.
-- Retourne nil si la souris n'est pas dans l'éditeur MIDI ou sur une ligne de note valide.
function PA_GetMidiEditorContext()
  local editor = reaper.MIDIEditor_GetActive()
  if not editor then return nil end

  local take = reaper.MIDIEditor_GetTake(editor)
  if not take then return nil end

  local window = reaper.BR_GetMouseCursorContext()
  if window ~= "midi_editor" and window ~= "midi_trackview" then return nil end

  local _, _, noteRow = reaper.BR_GetMouseCursorContext_MIDI()
  if noteRow == -1 then return nil end

  local mouse_time = reaper.BR_GetMouseCursorContext_Position()
  local mouse_ppq  = reaper.MIDI_GetPPQPosFromProjTime(take, mouse_time)

  return editor, take, mouse_ppq, noteRow
end

-- Retourne le PPQ cible en appliquant le snap MIDI si activé.
function PA_GetMidiTargetPPQ(editor, take, mouse_ppq)
  local snap_enabled = reaper.MIDIEditor_GetSetting_int(editor, "snap_enabled") == 1
  if snap_enabled then
    local grid_qn    = reaper.MIDI_GetGrid(take)
    local qn_pos     = reaper.MIDI_GetProjQNFromPPQPos(take, mouse_ppq)
    local snapped_qn = math.floor(qn_pos / grid_qn + 0.5) * grid_qn
    return reaper.MIDI_GetPPQPosFromProjQN(take, snapped_qn)
  else
    return math.floor(mouse_ppq + 0.5)
  end
end

-- Retourne le nombre de notes sélectionnées dans le take.
function PA_CountSelectedMidiNotes(take)
  local _, note_count = reaper.MIDI_CountEvts(take)
  local count = 0
  for i = 0, note_count - 1 do
    local _, sel = reaper.MIDI_GetNote(take, i)
    if sel then count = count + 1 end
  end
  return count
end

-- Trim le bord droit de toutes les notes sélectionnées à target_ppq (absolu).
function PA_TrimSelectedNotesRight(take, target_ppq)
  local _, note_count = reaper.MIDI_CountEvts(take)
  for i = 0, note_count - 1 do
    local _, sel, muted, startppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
    if sel and target_ppq > startppq then
      reaper.MIDI_SetNote(take, i, true, muted, startppq, target_ppq, chan, pitch, vel, false)
    end
  end
end

-- Trim le bord gauche de toutes les notes sélectionnées à target_ppq (absolu).
function PA_TrimSelectedNotesLeft(take, target_ppq)
  local _, note_count = reaper.MIDI_CountEvts(take)
  for i = 0, note_count - 1 do
    local _, sel, muted, startppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
    if sel and target_ppq < endppq then
      reaper.MIDI_SetNote(take, i, true, muted, target_ppq, endppq, chan, pitch, vel, false)
    end
  end
end

-- Déselectionne toutes les notes du take.
function PA_DeselectAllMidiNotes(take)
  local _, note_count = reaper.MIDI_CountEvts(take)
  for i = 0, note_count - 1 do
    local _, sel, muted, startppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
    if sel then
      reaper.MIDI_SetNote(take, i, false, muted, startppq, endppq, chan, pitch, vel, false)
    end
  end
end

-- Trim le bord droit d'une note unique sous la souris (même pitch), ou étend la note précédente.
-- Retourne true si une action a été effectuée.
function PA_TrimNoteRightUnderMouse(take, mouse_ppq, target_ppq, noteRow)
  PA_DeselectAllMidiNotes(take)
  local _, note_count = reaper.MIDI_CountEvts(take)
  local best_prev_idx, best_prev_end = nil, -math.huge

  for i = 0, note_count - 1 do
    local _, sel, muted, startppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
    if pitch == noteRow then
      if startppq < mouse_ppq and endppq > mouse_ppq then
        if target_ppq > startppq then
          reaper.MIDI_SetNote(take, i, true, muted, startppq, target_ppq, chan, pitch, vel, false)
        end
        return true
      elseif endppq <= mouse_ppq and endppq > best_prev_end then
        best_prev_idx = i
        best_prev_end = endppq
      end
    end
  end

  if best_prev_idx then
    local _, sel, muted, startppq, _, chan, pitch, vel = reaper.MIDI_GetNote(take, best_prev_idx)
    if target_ppq > startppq then
      reaper.MIDI_SetNote(take, best_prev_idx, true, muted, startppq, target_ppq, chan, pitch, vel, false)
      return true
    end
  end

  return false
end

-- Trim le bord gauche d'une note unique sous la souris (même pitch), ou étend la note suivante.
-- Retourne true si une action a été effectuée.
function PA_TrimNoteLeftUnderMouse(take, mouse_ppq, target_ppq, noteRow)
  PA_DeselectAllMidiNotes(take)
  local _, note_count = reaper.MIDI_CountEvts(take)
  local best_next_idx, best_next_start = nil, math.huge

  for i = 0, note_count - 1 do
    local _, sel, muted, startppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
    if pitch == noteRow then
      if startppq < mouse_ppq and endppq > mouse_ppq then
        if target_ppq < endppq then
          reaper.MIDI_SetNote(take, i, true, muted, target_ppq, endppq, chan, pitch, vel, false)
        end
        return true
      elseif startppq >= mouse_ppq and startppq < best_next_start then
        best_next_idx   = i
        best_next_start = startppq
      end
    end
  end

  if best_next_idx then
    local _, sel, muted, _, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, best_next_idx)
    if target_ppq < endppq then
      reaper.MIDI_SetNote(take, best_next_idx, true, muted, target_ppq, endppq, chan, pitch, vel, false)
      return true
    end
  end

  return false
end
