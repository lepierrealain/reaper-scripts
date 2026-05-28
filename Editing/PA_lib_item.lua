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
-- new_pos doit être à gauche de la position actuelle de l'item.
function PA_TrimItemLeft(item, new_pos)
  local item_start  = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_len    = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local delta       = item_start - new_pos
  local take        = reaper.GetActiveTake(item)

  reaper.SetMediaItemInfo_Value(item, "D_POSITION", new_pos)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH",   item_len + delta)
  if take then
    local playrate   = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
    local start_offs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
    reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", start_offs - delta * playrate)
  end
end

-- Trim le bord droit d'un item à new_end (modifie uniquement la longueur).
-- new_end doit être à droite du début de l'item.
function PA_TrimItemRight(item, new_end)
  local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", new_end - item_start)
end
