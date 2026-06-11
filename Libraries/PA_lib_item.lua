-- @description Item utility functions
-- @author lepierrealain
-- @version 1.0

-- Retourne une liste d'items liés à ref_item par même position+longueur, via :
--   - item group (I_GROUPID)
--   - track group (MEDIA_EDIT_LEAD/FOLLOW)
--   - sélection
-- ref_item lui-même n'est pas inclus. Pas de doublons.
function PA_GetRelatedItemsAtSamePosition(ref_item)
  local ref_pos    = reaper.GetMediaItemInfo_Value(ref_item, "D_POSITION")
  local ref_len    = reaper.GetMediaItemInfo_Value(ref_item, "D_LENGTH")
  local item_group = math.floor(reaper.GetMediaItemInfo_Value(ref_item, "I_GROUPID"))
  local ref_track  = reaper.GetMediaItemTrack(ref_item)

  local lead_mask   = reaper.GetSetTrackGroupMembership(ref_track, "MEDIA_EDIT_LEAD",   0, 0)
  local follow_mask = reaper.GetSetTrackGroupMembership(ref_track, "MEDIA_EDIT_FOLLOW", 0, 0)
  local ref_tg_mask = lead_mask | follow_mask

  -- Index des items sélectionnés pour lookup O(1)
  local selected = {}
  for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
    selected[reaper.GetSelectedMediaItem(0, i)] = true
  end

  local seen   = {}
  local result = {}

  local function add(candidate)
    if not seen[candidate] then
      seen[candidate] = true
      table.insert(result, candidate)
    end
  end

  for t = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, t)

    local in_track_group = false
    if ref_tg_mask ~= 0 and track ~= ref_track then
      local tl = reaper.GetSetTrackGroupMembership(track, "MEDIA_EDIT_LEAD",   0, 0)
      local tf = reaper.GetSetTrackGroupMembership(track, "MEDIA_EDIT_FOLLOW", 0, 0)
      if (ref_tg_mask & (tl | tf)) ~= 0 then in_track_group = true end
    end

    for i = 0, reaper.CountTrackMediaItems(track) - 1 do
      local candidate = reaper.GetTrackMediaItem(track, i)
      if candidate ~= ref_item then
        local c_pos = reaper.GetMediaItemInfo_Value(candidate, "D_POSITION")
        local c_len = reaper.GetMediaItemInfo_Value(candidate, "D_LENGTH")
        if math.abs(c_pos - ref_pos) < 0.0001 and math.abs(c_len - ref_len) < 0.0001 then
          local c_group = math.floor(reaper.GetMediaItemInfo_Value(candidate, "I_GROUPID"))
          if in_track_group
          or (item_group > 0 and c_group == item_group)
          or selected[candidate] then
            add(candidate)
          end
        end
      end
    end
  end

  return result
end

-- Retourne tous les items sélectionnés sauf ref_item, quelle que soit leur position.
function PA_GetAllSelectedItems(ref_item)
  local result = {}
  for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
    local candidate = reaper.GetSelectedMediaItem(0, i)
    if candidate ~= ref_item then
      table.insert(result, candidate)
    end
  end
  return result
end

-- Trim le bord gauche d'un item à new_pos (modifie position, longueur et start offset).
-- Pour les items MIDI, étend aussi la source si new_pos est avant le début actuel.
function PA_TrimItemLeft(item, new_pos)
  local item_start  = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_len    = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local delta       = item_start - new_pos
  local take        = reaper.GetActiveTake(item)

  reaper.SetMediaItemInfo_Value(item, "D_POSITION", new_pos)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH",   item_len + delta)
  if take then
    if reaper.TakeIsMIDI(take) then
      local playrate     = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
      local ticks_per_qn = 960
      local old_start_qn = reaper.TimeMap2_timeToQN(0, item_start)
      local new_start_qn = reaper.TimeMap2_timeToQN(0, new_pos)
      local extra_ticks  = math.floor((old_start_qn - new_start_qn) * ticks_per_qn * playrate + 0.5)
      local delta_soffs  = delta * playrate

      -- Récupérer le GUID de la source poolée avant de dépooler
      local pool_guid = nil
      local ok0, chunk0 = reaper.GetItemStateChunk(item, "", false)
      if ok0 then
        pool_guid = chunk0:match("POOLEDEVTS ({[^}]+})")
      end

      -- Dépooler uniquement cet item
      local sel_count = reaper.CountSelectedMediaItems(0)
      local prev_sel  = {}
      for i = 0, sel_count - 1 do prev_sel[i] = reaper.GetSelectedMediaItem(0, i) end
      reaper.SelectAllMediaItems(0, false)
      reaper.SetMediaItemSelected(item, true)
      reaper.Main_OnCommand(40861, 0) -- MIDI: Unpool MIDI source
      reaper.SelectAllMediaItems(0, false)
      for _, sel_item in pairs(prev_sel) do reaper.SetMediaItemSelected(sel_item, true) end

      -- Modifier le chunk pour étendre la source
      local ok, chunk = reaper.GetItemStateChunk(item, "", false)
      if ok then
        local replaced = false
        chunk = chunk:gsub("(Em )(%d+)( 90 00 01)", function(a, offset_str, b)
          if not replaced then
            replaced = true
            return a .. (tonumber(offset_str) + extra_ticks) .. b
          end
        end)
        if not replaced then
          chunk = chunk:gsub("(HASDATA 1 %d+ QN\n)", "%1Em " .. extra_ticks .. " 90 00 01\nEm 1 80 00 00\n")
        end
        reaper.SetItemStateChunk(item, chunk, false)
      end

      -- Compenser le décalage sur toutes les autres instances poolées
      if pool_guid then
        for t = 0, reaper.CountTracks(0) - 1 do
          local track = reaper.GetTrack(0, t)
          for i = 0, reaper.CountTrackMediaItems(track) - 1 do
            local other = reaper.GetTrackMediaItem(track, i)
            if other ~= item then
              local other_take = reaper.GetActiveTake(other)
              if other_take and reaper.TakeIsMIDI(other_take) then
                local ok2, chunk2 = reaper.GetItemStateChunk(other, "", false)
                if ok2 and chunk2:find(pool_guid, 1, true) then
                  local other_soffs = reaper.GetMediaItemTakeInfo_Value(other_take, "D_STARTOFFS")
                  reaper.SetMediaItemTakeInfo_Value(other_take, "D_STARTOFFS", other_soffs + delta_soffs)
                end
              end
            end
          end
        end
      end
    else
      local playrate   = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
      local start_offs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
      reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", start_offs - delta * playrate)
    end
  end
end

-- Trim le bord droit d'un item à new_end (modifie uniquement la longueur).
-- Pour les items MIDI, étend aussi la source en insérant une note muette à la cible.
function PA_TrimItemRight(item, new_end)
  local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", new_end - item_start)
  local take = reaper.GetActiveTake(item)
  if take and reaper.TakeIsMIDI(take) then
    local target_ppq = reaper.MIDI_GetPPQPosFromProjTime(take, new_end)
    reaper.MIDI_InsertNote(take, false, true, target_ppq - 1, target_ppq, 0, 0, 1, true)
    reaper.MIDI_Sort(take)
  end
end
