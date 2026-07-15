-- @description Space items with silence
-- @author lepierrealain
-- @version 1.0

-- Supprime les espaces entre les items sélectionnés, puis insère x secondes
-- de silence entre chaque item. Les items sont triés par position sur la timeline.

local function main()
  -- Récupérer les items sélectionnés
  local count = reaper.CountSelectedMediaItems(0)
  if count < 2 then
    reaper.MB("Sélectionne au moins 2 items.", "Espace entre items", 0)
    return
  end

  -- Demander la durée du silence
  local ok, input = reaper.GetUserInputs(
    "Silence entre items", 1,
    "Durée du silence (secondes) :",
    "1.0"
  )
  if not ok then return end

  local silence = tonumber(input)
  if not silence or silence < 0 then
    reaper.MB("Valeur invalide. Entrez un nombre >= 0.", "Espace entre items", 0)
    return
  end

  -- Collecter et trier les items par position de départ
  local items = {}
  for i = 0, count - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local pos  = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local len  = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    table.insert(items, { item = item, pos = pos, len = len })
  end
  table.sort(items, function(a, b) return a.pos < b.pos end)

  -- Undo block
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  -- Coller les items les uns contre les autres puis insérer le silence
  -- On place le premier item à sa position actuelle (on ne le bouge pas),
  -- puis on enchaîne les suivants.
  local cursor = items[1].pos + items[1].len

  for i = 2, #items do
    local new_pos = cursor + silence
    reaper.SetMediaItemInfo_Value(items[i].item, "D_POSITION", new_pos)
    cursor = new_pos + items[i].len
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock(
    string.format("Silence de %.3f s entre items sélectionnés", silence),
    -1
  )

  reaper.MB(
    string.format(
      "%d items repositionnés avec %.3f s de silence entre chaque.",
      count, silence
    ),
    "Espace entre items", 0
  )
end

main()
