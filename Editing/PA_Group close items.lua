-- @description Group close items
-- @author lepierrealain
-- @version 1.0

-- Groupe les items proches parmi une sélection d'items.
-- Le script demande jusqu'à combien de secondes de vide (gap) entre deux items
-- ceux-ci restent dans le même groupe. Chaque groupe reçoit un nouvel ID de
-- groupe REAPER. Le groupement est global : les items de toutes les pistes sont
-- triés par position sur la timeline, sans distinction de piste.

local function main()
  -- Récupérer les items sélectionnés
  local count = reaper.CountSelectedMediaItems(0)
  if count < 2 then
    reaper.MB("Sélectionne au moins 2 items.", "Grouper items proches", 0)
    return
  end

  -- Demander le gap maximum
  local ok, input = reaper.GetUserInputs(
    "Grouper items proches", 1,
    "Vide max entre items (secondes) :",
    "1.0"
  )
  if not ok then return end

  local max_gap = tonumber(input)
  if not max_gap or max_gap < 0 then
    reaper.MB("Valeur invalide. Entrez un nombre >= 0.", "Grouper items proches", 0)
    return
  end

  -- Collecter les items avec leur position et leur fin
  local items = {}
  for i = 0, count - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local pos  = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local len  = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    table.insert(items, { item = item, pos = pos, fin = pos + len })
  end

  -- Trier par position de départ sur la timeline (toutes pistes confondues)
  table.sort(items, function(a, b) return a.pos < b.pos end)

  -- Trouver le plus grand ID de groupe déjà utilisé dans le projet pour ne pas
  -- écraser des groupes existants.
  local max_group_id = 0
  local total = reaper.CountMediaItems(0)
  for i = 0, total - 1 do
    local g = reaper.GetMediaItemInfo_Value(reaper.GetMediaItem(0, i), "I_GROUPID")
    if g > max_group_id then max_group_id = g end
  end

  -- Undo block
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  -- Parcourir les items triés et constituer des clusters d'items proches.
  -- Un cluster démarre sur le premier item ; tant que le vide qui précède
  -- l'item suivant est <= max_gap, il rejoint le cluster (toutes pistes
  -- confondues). Un cluster de 2 items ou plus devient un groupe.
  local groups_created = 0
  local grouped_items  = 0

  local function commit(cluster)
    if #cluster >= 2 then
      max_group_id = max_group_id + 1
      for _, it in ipairs(cluster) do
        reaper.SetMediaItemInfo_Value(it.item, "I_GROUPID", max_group_id)
      end
      groups_created = groups_created + 1
      grouped_items  = grouped_items + #cluster
    end
  end

  local cluster = { items[1] }
  local cluster_end = items[1].fin

  for i = 2, #items do
    local it = items[i]
    -- Gap = distance entre la fin du cluster courant et le début de l'item.
    -- Si l'item chevauche le cluster, gap est négatif donc <= max_gap.
    local gap = it.pos - cluster_end

    if gap <= max_gap then
      table.insert(cluster, it)
      if it.fin > cluster_end then cluster_end = it.fin end
    else
      commit(cluster)
      cluster = { it }
      cluster_end = it.fin
    end
  end
  commit(cluster)

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock(
    string.format("Grouper items proches (vide <= %.3f s)", max_gap),
    -1
  )

  reaper.MB(
    string.format(
      "%d groupe(s) créé(s) pour %d items (vide max : %.3f s).",
      groups_created, grouped_items, max_gap
    ),
    "Grouper items proches", 0
  )
end

main()
