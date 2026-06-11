-- @description Duplicate item to fill measure
-- @author lepierrealain
-- @version 1.0
--
-- Duplique l'item sélectionné juste après lui-même.
-- Si la piste est en mode Beats, cale la copie sur la mesure :
--   - Item trop court (ne remplit pas la mesure) → copie au début de la mesure suivante
--   - Item dépasse la mesure de moins de 25% → copie juste après l'item
--   - Item dépasse de plus de 25% → copie au début de la prochaine mesure après l'item


local function duplicate_item_at(item, dest_pos)
  local track = reaper.GetMediaItemTrack(item)
  local _, chunk = reaper.GetItemStateChunk(item, "", false)
  local new_item = reaper.AddMediaItemToTrack(track)
  reaper.SetItemStateChunk(new_item, chunk, false)
  reaper.SetMediaItemPosition(new_item, dest_pos, false)
end

local function main()
  if reaper.CountSelectedMediaItems(0) == 0 then return end

  local items = {}
  for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
    items[#items + 1] = reaper.GetSelectedMediaItem(0, i)
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  for _, item in ipairs(items) do
    local track     = reaper.GetMediaItemTrack(item)
    local beat_mode = reaper.GetMediaTrackInfo_Value(track, "C_BEATATTACHMODE")
    local item_pos  = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_end  = item_pos + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

    local dest_pos

    if beat_mode >= 1 then
      local _, start_measure_idx = reaper.TimeMap2_timeToBeats(0, item_pos)
      local start_measure_end    = reaper.TimeMap2_beatsToTime(0, 0, start_measure_idx + 1)

      if item_end <= start_measure_end - 1e-6 then
        -- Trop court : copie sur la mesure suivante
        dest_pos = start_measure_end
      else
        local _, end_measure_idx  = reaper.TimeMap2_timeToBeats(0, item_end)
        local end_measure_start   = reaper.TimeMap2_beatsToTime(0, 0, end_measure_idx)
        local end_measure_end     = reaper.TimeMap2_beatsToTime(0, 0, end_measure_idx + 1)
        local end_measure_len     = end_measure_end - end_measure_start
        local overshoot           = item_end - end_measure_start

        if overshoot < end_measure_len * 0.25 then
          -- Dépasse peu : copie au début de la mesure où l'item finit
          dest_pos = end_measure_start
        else
          -- Dépasse beaucoup : copie sur la mesure suivante
          dest_pos = end_measure_end
        end
      end
    else
      dest_pos = item_end
    end

    duplicate_item_at(item, dest_pos)
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Duplicate item to fill measure", -1)
end

main()
