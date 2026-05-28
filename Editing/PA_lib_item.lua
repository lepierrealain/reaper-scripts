-- @description Item utility functions
-- @author lepierrealain
-- @version 1.0

-- Retourne une liste d'items partageant la même position que ref_item,
-- en tenant compte des item groups et des track groups (MEDIA_EDIT).
-- ref_item lui-même n'est pas inclus dans la liste retournée.
function PA_GetGroupedItemsAtSamePosition(ref_item)
  local ref_pos    = reaper.GetMediaItemInfo_Value(ref_item, "D_POSITION")
  local ref_len    = reaper.GetMediaItemInfo_Value(ref_item, "D_LENGTH")
  local item_group = math.floor(reaper.GetMediaItemInfo_Value(ref_item, "I_GROUPID"))
  local ref_track  = reaper.GetMediaItemTrack(ref_item)

  -- Construit le set des track groups (MEDIA_EDIT) de la piste de ref_item
  local ref_track_groups = {}
  for g = 1, 32 do
    local low  = reaper.GetSetTrackGroupMembership(ref_track, "MEDIA_EDIT_LEAD",   0, 0)
    local low2 = reaper.GetSetTrackGroupMembership(ref_track, "MEDIA_EDIT_FOLLOW", 0, 0)
    -- GetSetTrackGroupMembership retourne un bitmask 32 bits (groupes 1-32)
    -- On reconstruit le set complet une seule fois
    break
  end
  local lead_mask   = reaper.GetSetTrackGroupMembership(ref_track, "MEDIA_EDIT_LEAD",   0, 0)
  local follow_mask = reaper.GetSetTrackGroupMembership(ref_track, "MEDIA_EDIT_FOLLOW", 0, 0)
  local ref_tg_mask = lead_mask | follow_mask

  local result = {}
  local num_tracks = reaper.CountTracks(0)

  for t = 0, num_tracks - 1 do
    local track = reaper.GetTrack(0, t)
    if track ~= ref_track then
      local in_item_group   = false
      local in_track_group  = false

      -- Check track group : la piste candidate doit partager au moins un bit MEDIA_EDIT
      if ref_tg_mask ~= 0 then
        local tl = reaper.GetSetTrackGroupMembership(track, "MEDIA_EDIT_LEAD",   0, 0)
        local tf = reaper.GetSetTrackGroupMembership(track, "MEDIA_EDIT_FOLLOW", 0, 0)
        if (ref_tg_mask & (tl | tf)) ~= 0 then
          in_track_group = true
        end
      end

      local num_items = reaper.CountTrackMediaItems(track)
      for i = 0, num_items - 1 do
        local candidate = reaper.GetTrackMediaItem(track, i)
        local c_pos = reaper.GetMediaItemInfo_Value(candidate, "D_POSITION")
        local c_len = reaper.GetMediaItemInfo_Value(candidate, "D_LENGTH")

        -- Même position et même longueur
        if math.abs(c_pos - ref_pos) < 0.0001 and math.abs(c_len - ref_len) < 0.0001 then
          -- Check item group
          if item_group > 0 then
            local c_group = math.floor(reaper.GetMediaItemInfo_Value(candidate, "I_GROUPID"))
            if c_group == item_group then
              in_item_group = true
            end
          end

          if in_item_group or in_track_group then
            table.insert(result, candidate)
          end
        end
      end
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
  local start_offs  = take and reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS") or 0

  reaper.SetMediaItemInfo_Value(item, "D_POSITION", new_pos)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH",   item_len + delta)
  if take then
    reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", start_offs - delta)
  end
end

-- Trim le bord droit d'un item à new_end (modifie uniquement la longueur).
-- new_end doit être à droite du début de l'item.
function PA_TrimItemRight(item, new_end)
  local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", new_end - item_start)
end
