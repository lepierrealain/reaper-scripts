-- @description Duplicate item to fill measure
-- @author lepierrealain
-- @version 1.1
--
-- Duplique le(s) item(s) sélectionné(s) juste après la sélection.
-- Si plusieurs items sont sélectionnés, ils sont traités comme un groupe :
-- la destination est calculée d'après la FIN de la sélection (item le plus à
-- droite) et tous les items sont recopiés avec le même décalage, conservant
-- ainsi leur disposition relative.
-- Si la piste est en mode Beats, cale la copie sur la mesure :
--   - Sélection trop courte (ne remplit pas la mesure) → copie au début de la mesure suivante
--   - Sélection dépasse la mesure de moins de 25% → copie juste après la sélection
--   - Sélection dépasse de plus de 25% → copie au début de la prochaine mesure après la sélection


local function duplicate_item_with_offset(item, offset)
  local track    = reaper.GetMediaItemTrack(item)
  local _, chunk = reaper.GetItemStateChunk(item, "", false)
  local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local new_item = reaper.AddMediaItemToTrack(track)
  reaper.SetItemStateChunk(new_item, chunk, false)
  reaper.SetMediaItemPosition(new_item, item_pos + offset, false)
  return new_item
end

local function main()
  if reaper.CountSelectedMediaItems(0) == 0 then return end

  local items = {}
  for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
    items[#items + 1] = reaper.GetSelectedMediaItem(0, i)
  end

  -- Étendue de la sélection : début le plus à gauche, fin le plus à droite.
  local sel_start = math.huge
  local sel_end   = -math.huge
  -- Mode Beats déterminé par l'item qui finit le plus à droite.
  local last_item
  for _, item in ipairs(items) do
    local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_end = item_pos + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    if item_pos < sel_start then sel_start = item_pos end
    if item_end > sel_end then
      sel_end   = item_end
      last_item = item
    end
  end

  local beat_mode = reaper.GetMediaTrackInfo_Value(reaper.GetMediaItemTrack(last_item), "C_BEATATTACHMODE")

  -- Position de destination du début de la sélection.
  local dest_start

  if beat_mode >= 1 then
    local _, start_measure_idx = reaper.TimeMap2_timeToBeats(0, sel_start)
    local start_measure_end    = reaper.TimeMap2_beatsToTime(0, 0, start_measure_idx + 1)

    if sel_end <= start_measure_end - 1e-6 then
      -- Trop court : copie sur la mesure suivante
      dest_start = start_measure_end
    else
      local _, end_measure_idx = reaper.TimeMap2_timeToBeats(0, sel_end)
      local end_measure_start  = reaper.TimeMap2_beatsToTime(0, 0, end_measure_idx)
      local end_measure_end    = reaper.TimeMap2_beatsToTime(0, 0, end_measure_idx + 1)
      local end_measure_len    = end_measure_end - end_measure_start
      local overshoot          = sel_end - end_measure_start

      if overshoot < end_measure_len * 0.25 then
        -- Dépasse peu : copie au début de la mesure où la sélection finit
        dest_start = end_measure_start
      else
        -- Dépasse beaucoup : copie sur la mesure suivante
        dest_start = end_measure_end
      end
    end
  else
    dest_start = sel_end
  end

  -- Décalage commun appliqué à tous les items pour préserver leur disposition.
  local offset = dest_start - sel_start

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local new_items = {}
  for _, item in ipairs(items) do
    new_items[#new_items + 1] = duplicate_item_with_offset(item, offset)
  end

  -- Ne garder sélectionnés que les items dupliqués.
  for _, item in ipairs(items) do
    reaper.SetMediaItemSelected(item, false)
  end
  for _, item in ipairs(new_items) do
    reaper.SetMediaItemSelected(item, true)
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Duplicate item to fill measure", -1)
end

main()
