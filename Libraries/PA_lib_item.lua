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

-- Retourne le GUID de pool MIDI d'un item (ligne POOLEDEVTS du chunk), ou nil si l'item
-- n'a pas de source MIDI poolée. Deux items partageant le même GUID sont dans le même pool.
local function GetMidiPoolGUID(item)
  local ok, chunk = reaper.GetItemStateChunk(item, "", false)
  if not ok then return nil end
  -- Tolère la présence ou non d'accolades autour du GUID.
  return chunk:match("POOLEDEVTS%s+{?(%x+%-%x+%-%x+%-%x+%-%x+)}?")
end

-- Retourne true si la take MIDI de l'item partage son pool MIDI avec au moins un autre item
-- du projet (item "poolé"). La comparaison se fait sur le GUID POOLEDEVTS du chunk.
function PA_IsMidiItemPooled(item)
  local take = reaper.GetActiveTake(item)
  if not take or not reaper.TakeIsMIDI(take) then return false end

  local pool_guid = GetMidiPoolGUID(item)
  if not pool_guid then return false end

  for t = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, t)
    for i = 0, reaper.CountTrackMediaItems(track) - 1 do
      local cand = reaper.GetTrackMediaItem(track, i)
      if cand ~= item and GetMidiPoolGUID(cand) == pool_guid then
        return true
      end
    end
  end
  return false
end

-- Collecte les autres items du même pool MIDI que ref_item (ref_item exclu).
-- Retourne une liste de tables { track, pos, len, startoffs }.
local function CollectPoolSiblings(ref_item)
  local ref_guid = GetMidiPoolGUID(ref_item)
  local siblings = {}
  if not ref_guid then return siblings end
  for t = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, t)
    for i = 0, reaper.CountTrackMediaItems(track) - 1 do
      local cand = reaper.GetTrackMediaItem(track, i)
      if cand ~= ref_item and GetMidiPoolGUID(cand) == ref_guid then
        local ctake = reaper.GetActiveTake(cand)
        siblings[#siblings + 1] = {
          track    = track,
          pos      = reaper.GetMediaItemInfo_Value(cand, "D_POSITION"),
          len      = reaper.GetMediaItemInfo_Value(cand, "D_LENGTH"),
          startoffs = ctake and reaper.GetMediaItemTakeInfo_Value(ctake, "D_STARTOFFS") or 0,
        }
      end
    end
  end
  return siblings
end

-- Duplique src_item (item MIDI poolé) sur dest_track à la position dest_pos, en conservant
-- le pool (même POOLEDEVTS) mais en régénérant le GUID de take pour éviter toute collision.
-- Retourne le nouvel item.
local function DuplicatePooledItem(src_item, dest_track, dest_pos)
  local _, chunk = reaper.GetItemStateChunk(src_item, "", false)
  -- Régénère le GUID de la take (lignes "GUID {...}" et "IGUID {...}") pour rester unique.
  chunk = chunk:gsub("(\n%s*GUID%s+){%x+%-%x+%-%x+%-%x+%-%x+}", "%1" .. reaper.genGuid(""), 1)
  chunk = chunk:gsub("(\n%s*IGUID%s+){%x+%-%x+%-%x+%-%x+%-%x+}", "%1" .. reaper.genGuid(""), 1)

  local new_item = reaper.AddMediaItemToTrack(dest_track)
  reaper.SetItemStateChunk(new_item, chunk, false)
  reaper.SetMediaItemInfo_Value(new_item, "D_POSITION", dest_pos)
  return new_item
end

-- Trim un item MIDI aux bornes [target_pos, target_pos + target_len] sans toucher au
-- contenu (ajuste position, longueur et start offset). Suppose target inclus dans l'item.
local function TrimMidiItemTo(item, target_pos, target_len)
  local pos  = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local take = reaper.GetActiveTake(item)
  local left_delta = target_pos - pos -- portion à retirer à gauche (>= 0)
  if take and left_delta ~= 0 then
    local playrate   = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
    local start_offs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
    reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", start_offs + left_delta * playrate)
  end
  reaper.SetMediaItemInfo_Value(item, "D_POSITION", target_pos)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH",   target_len)
end

-- Étend vers la gauche un item MIDI poolé, approche par glue + duplication.
-- 1) Crée un item vide [new_pos -> item_start] et le glue avec la cible : un seul item
--    [new_pos -> item_end] avec le bon contenu MIDI, sans toucher startoffs/buffer.
-- 2) Pour chaque autre item du pool : le supprime, duplique l'item glué aligné sur le
--    contenu, puis le trimme à ses bornes d'origine (la copie se repoole automatiquement).
function PA_ExtendPooledMidiItemLeft(item, new_pos, take, item_start, item_len)
  local track   = reaper.GetMediaItemTrack(item)
  local item_end = item_start + item_len
  -- Origine du pool projetée (position projet du début de la source partagée) : c'est la
  -- référence commune à tous les items du pool. La cible la fixe via son propre startoffs.
  local target_startoffs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  local pool_origin = item_start - target_startoffs

  -- Collecter les autres items du pool AVANT de modifier quoi que ce soit.
  local siblings = CollectPoolSiblings(item)

  reaper.PreventUIRefresh(1)

  -- On ne doit gluer que si on étend AU-DELÀ du contenu déjà présent dans la source : tant
  -- que new_pos reste après l'origine du pool (= début de la source), 41305 ne fait que
  -- révéler du contenu caché, donc inutile de gluer (et d'afficher la fenêtre "consolidating").
  -- Marge d'un tick pour absorber les arrondis de tempo.
  local needs_glue = new_pos < pool_origin - 1e-9

  -- Fin réelle de la source MIDI (position projet du dernier tick de la source partagée).
  -- Sert à ne pas tronquer le contenu à droite lors du glue.
  local src_len_ppq = reaper.BR_GetMidiSourceLenPPQ(take)
  local src_end = item_end
  if src_len_ppq and src_len_ppq > 0 then
    -- PPQ de la source comptés depuis pool_origin ; convertir en temps projet.
    local origin_ppq = reaper.MIDI_GetPPQPosFromProjTime(take, pool_origin)
    src_end = reaper.MIDI_GetProjTimeFromPPQPos(take, origin_ppq + src_len_ppq)
  end

  -- 1) Étendre le bord gauche de la cible jusqu'au curseur (action native, aucune perte de
  --    données). Si la source n'est pas assez longue, gluer pour matérialiser le contenu
  --    étendu dans une source indépendante (l'extension seule ne l'allonge pas).
  local cur_pos = reaper.GetCursorPosition()
  reaper.SelectAllMediaItems(0, false)
  reaper.SetMediaItemSelected(item, true)
  reaper.SetEditCurPos(new_pos, false, false)
  reaper.Main_OnCommand(41305, 0) -- Item edge: Trim left edge of item to edit cursor
  if needs_glue then
    -- Avant le glue, étendre aussi le bord droit jusqu'au bout de la source pour ne rien
    -- perdre (le glue tronquerait le contenu au-delà du bord droit), puis re-trimmer ensuite.
    if src_end > item_end then
      reaper.SetMediaItemInfo_Value(item, "D_LENGTH",
        src_end - reaper.GetMediaItemInfo_Value(item, "D_POSITION"))
    end
    reaper.Main_OnCommand(40362, 0) -- Item: Glue items (fige le contenu, source indépendante)
  end
  reaper.SetEditCurPos(cur_pos, false, false)
  local glued = reaper.GetSelectedMediaItem(0, 0)
  if needs_glue and src_end > item_end then
    -- Re-trimmer le bord droit à la fin d'origine de la cible.
    reaper.SetMediaItemInfo_Value(glued, "D_LENGTH",
      item_end - reaper.GetMediaItemInfo_Value(glued, "D_POSITION"))
  end

  -- Donner à la cible glué un GUID de pool neuf, partagé ensuite avec les copies des siblings.
  local pool_guid = reaper.genGuid("")
  do
    local _, gchunk = reaper.GetItemStateChunk(glued, "", false)
    local repl
    gchunk, repl = gchunk:gsub("(POOLEDEVTS%s+)%S+", "%1" .. pool_guid, 1)
    if repl == 0 then
      -- Pas de ligne POOLEDEVTS : l'ajouter dans le bloc <SOURCE MIDI...> (après HASDATA).
      gchunk = gchunk:gsub("(HASDATA[^\n]*\n)", "%1POOLEDEVTS " .. pool_guid .. "\n", 1)
    end
    -- Retirer le suffixe "-glued" ajouté au nom de la take.
    gchunk = gchunk:gsub('(NAME%s+"[^"]-)%-glued(")', "%1%2", 1)
    gchunk = gchunk:gsub("(NAME%s+[^%s\"]-)%-glued(\n)", "%1%2", 1)
    reaper.SetItemStateChunk(glued, gchunk, false)
  end

  -- 2) Reconstruire chaque sibling par duplication de l'item glué.
  for _, sib in ipairs(siblings) do
    -- Supprimer l'ancien sibling (on le retrouve par position sur sa piste).
    for i = reaper.CountTrackMediaItems(sib.track) - 1, 0, -1 do
      local it = reaper.GetTrackMediaItem(sib.track, i)
      if math.abs(reaper.GetMediaItemInfo_Value(it, "D_POSITION") - sib.pos) < 1e-6 then
        reaper.DeleteTrackMediaItem(sib.track, it)
        break
      end
    end
    -- Aligner par l'ORIGINE DU POOL (pas par le début d'item), pour gérer les siblings déjà
    -- trimés à l'intérieur (startoffs non nul). Dans glued, le contenu pool d'offset "so"
    -- depuis l'origine est à la position projet (pool_origin + so). Le sibling l'affichait à
    -- sa position sib.pos. On décale donc la copie de d pour faire coïncider les deux :
    --   (pool_origin + sib.startoffs) + d = sib.pos  ->  d = sib.pos - sib.startoffs - pool_origin
    local d = sib.pos - sib.startoffs - pool_origin
    local dup_pos = new_pos + d
    local dup = DuplicatePooledItem(glued, sib.track, dup_pos)
    TrimMidiItemTo(dup, sib.pos, sib.len)
  end

  -- Ne laisser sélectionné que l'item qu'on vient d'étendre.
  reaper.SelectAllMediaItems(0, false)
  reaper.SetMediaItemSelected(glued, true)

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  return glued
end

-- Trim le bord gauche d'un item à new_pos (modifie position, longueur et start offset).
-- Retourne l'item résultant : le même en général, mais un NOUVEL item si l'item MIDI
-- poolé a dû être dé-poolé (l'ancien pointeur est alors invalide). Les appelants qui
-- réutilisent l'item après l'appel doivent récupérer cette valeur de retour.
function PA_TrimItemLeft(item, new_pos)
  local item_start  = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_len    = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local delta       = item_start - new_pos
  local take        = reaper.GetActiveTake(item)

  if take and reaper.TakeIsMIDI(take) and delta > 0 and PA_IsMidiItemPooled(item) then
    -- Cas problématique : étendre vers la gauche un item MIDI poolé. La source MIDI
    -- est partagée, on ne peut pas l'allonger sans affecter les autres items du pool.
    -- Solution : copier le MIDI, supprimer l'item, recréer un item indépendant (unpool)
    -- commençant à new_pos, et recoller le MIDI décalé pour garder les notes en place.
    return PA_ExtendPooledMidiItemLeft(item, new_pos, take, item_start, item_len)
  end

  if take and reaper.TakeIsMIDI(take) then
    -- Pour le MIDI, déléguer à l'action native (gère correctement l'agrandissement
    -- de la source en extension, comme le trim souris).
    reaper.PreventUIRefresh(1)
    local cur_pos = reaper.GetCursorPosition()
    local prev_sel = {}
    for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
      prev_sel[i] = reaper.GetSelectedMediaItem(0, i)
    end
    reaper.SelectAllMediaItems(0, false)
    reaper.SetMediaItemSelected(item, true)
    reaper.SetEditCurPos(new_pos, false, false)
    reaper.Main_OnCommand(41305, 0) -- Item edge: Trim left edge of item to edit cursor
    reaper.SelectAllMediaItems(0, false)
    for _, sel_item in pairs(prev_sel) do
      if reaper.ValidatePtr(sel_item, "MediaItem*") then
        reaper.SetMediaItemSelected(sel_item, true)
      end
    end
    reaper.SetEditCurPos(cur_pos, false, false)
    reaper.PreventUIRefresh(-1)
    return item
  end

  reaper.SetMediaItemInfo_Value(item, "D_POSITION", new_pos)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH",   item_len + delta)
  if take then
    local playrate   = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
    local start_offs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
    reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", start_offs - delta * playrate)
  end
  return item
end

-- Trim le bord droit d'un item à new_end (modifie uniquement la longueur).
-- Pour les items MIDI en extension (new_end après la fin actuelle), étend aussi la source.
function PA_TrimItemRight(item, new_end)
  local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_end   = item_start + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", new_end - item_start)
  local take = reaper.GetActiveTake(item)
  if take and reaper.TakeIsMIDI(take) and new_end > item_end then
    local target_ppq = reaper.MIDI_GetPPQPosFromProjTime(take, new_end)
    reaper.MIDI_InsertNote(take, false, true, target_ppq - 1, target_ppq, 0, 0, 1, true)
    reaper.MIDI_Sort(take)
  end
end
