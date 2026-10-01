-- @description Group items from selected tracks by similar take names
-- @author lepierrealain
-- @version 1.1
-- @requires ReaImGui
-- @about
--   Replaces a contiguous block of selected tracks with tracks grouped by
--   take name. Overlapping items use extra tracks. The slider sets the
--   minimum name similarity; 100% groups only exactly identical names.

local PROJECT = 0
local TITLE = "Group items by name"

if not reaper.ImGui_CreateContext then
  reaper.ShowMessageBox("Ce script nécessite ReaImGui (disponible via ReaPack).", TITLE, 0)
  return
end

-- Le score compare les mots et les paires de caractères. Cette combinaison
-- rapproche les variantes de nom et tolère les petites fautes de frappe.
local function tokens(name)
  local result = {}
  for word in name:lower():gmatch("[%w\128-\255]+") do
    result[word] = (result[word] or 0) + 1
  end
  return result
end

local function bigrams(name)
  local result = {}
  local normalized = name:lower():gsub("[^%w\128-\255]+", " ")
    :gsub("^%s+", ""):gsub("%s+$", "")
  for i = 1, #normalized - 1 do
    local pair = normalized:sub(i, i + 1)
    result[pair] = (result[pair] or 0) + 1
  end
  return result
end

local function dice(a, b)
  local total_a, total_b, common = 0, 0, 0
  for key, count in pairs(a) do
    total_a = total_a + count
    common = common + math.min(count, b[key] or 0)
  end
  for _, count in pairs(b) do total_b = total_b + count end
  if total_a + total_b == 0 then return 0 end
  return 200 * common / (total_a + total_b)
end

local score_cache, feature_cache = {}, {}
local function features(name)
  if not feature_cache[name] then
    feature_cache[name] = {words = tokens(name), pairs = bigrams(name)}
  end
  return feature_cache[name]
end

local function finalNumber(name)
  return name:match("(%d+)%s*%.[%a%d]+%s*$") or
    name:match("(%d+)%s*$")
end

local function nameSimilarity(a, b)
  if a == b then return 100 end
  local key_a, key_b = a, b
  if key_b < key_a then key_a, key_b = key_b, key_a end
  local key = key_a .. "\0" .. key_b
  if score_cache[key] then return score_cache[key] end
  local left, right = features(a), features(b)
  local score = math.max(dice(left.words, right.words),
    dice(left.pairs, right.pairs))
  score_cache[key] = score
  return score
end

local function similarity(a, b)
  -- Le numéro final identifie généralement une prise distincte. Il bloque
  -- la fusion, mais pas le rapprochement visuel des pistes.
  if finalNumber(a) ~= finalNumber(b) then return 0 end
  return nameSimilarity(a, b)
end

local function collectSelection()
  local count = reaper.CountSelectedTracks(PROJECT)
  if count == 0 then return nil, "Sélectionne un bloc de pistes à remplacer." end
  local tracks, first_index, parent = {}, nil, nil
  for i = 0, count - 1 do
    local track = reaper.GetSelectedTrack(PROJECT, i)
    local index = math.floor(reaper.GetMediaTrackInfo_Value(track,
      "IP_TRACKNUMBER")) - 1
    local track_parent = reaper.GetParentTrack(track)
    local depth = reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH")
    if depth > 0 then
      return nil, "La sélection contient une piste dossier. Sélectionne seulement des pistes sans enfants."
    end
    if i == 0 then
      first_index, parent = index, track_parent
    elseif index ~= first_index + i or track_parent ~= parent then
      return nil, "Sélectionne des pistes consécutives dans le même dossier."
    end
    if depth < 0 and i < count - 1 then
      return nil, "Une piste ferme un dossier au milieu de la sélection."
    end
    tracks[#tracks + 1] = track
  end

  local items, unnamed = {}, 0
  for _, track in ipairs(tracks) do
    for j = 0, reaper.CountTrackMediaItems(track) - 1 do
      local item = reaper.GetTrackMediaItem(track, j)
      local take = reaper.GetActiveTake(item)
      local name = take and reaper.GetTakeName(take) or ""
      name = name:match("^%s*(.-)%s*$")
      if name == "" then
        name = "Sans nom"
        unnamed = unnamed + 1
      end
      items[#items + 1] = {
        item = item, name = name,
        position = reaper.GetMediaItemInfo_Value(item, "D_POSITION"),
        length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      }
    end
  end
  if #items == 0 then
    return nil, "Les pistes sélectionnées ne contiennent aucun item."
  end
  return {tracks = tracks, first_index = first_index,
    closing_depth = reaper.GetMediaTrackInfo_Value(tracks[#tracks],
      "I_FOLDERDEPTH"), items = items, unnamed = unnamed}
end

local function makeGroups(items, threshold)
  local groups, by_name = {}, {}
  for _, entry in ipairs(items) do
    local group = by_name[entry.name]
    if not group and threshold < 100 then
      local best_score = threshold
      for _, candidate in ipairs(groups) do
        -- Compare à chaque nom du groupe : une chaîne de ressemblances
        -- successives ne doit pas réunir deux noms trop différents.
        local minimum = 100
        for _, name in ipairs(candidate.names) do
          minimum = math.min(minimum, similarity(entry.name, name))
          if minimum < best_score then break end
        end
        if minimum >= best_score then
          if minimum > best_score or not group then
            group, best_score = candidate, minimum
          end
        end
      end
    end
    if not group then
      group = {label = entry.name, names = {}, items = {}}
      groups[#groups + 1] = group
    end
    if not by_name[entry.name] then
      group.names[#group.names + 1] = entry.name
      by_name[entry.name] = group
    end
    group.items[#group.items + 1] = entry
  end
  return groups
end

local function orderGroups(groups)
  if #groups < 2 then return groups end
  local remaining, ordered = {}, {}
  for _, group in ipairs(groups) do remaining[#remaining + 1] = group end
  table.sort(remaining, function(a, b) return a.label < b.label end)
  ordered[1] = table.remove(remaining, 1)
  while #remaining > 0 do
    local previous, best_index, best_score = ordered[#ordered], 1, -1
    for i, group in ipairs(remaining) do
      local score = nameSimilarity(previous.label, group.label)
      if score > best_score then best_index, best_score = i, score end
    end
    ordered[#ordered + 1] = table.remove(remaining, best_index)
  end
  return ordered
end

local function planTracks(items, threshold)
  local groups = orderGroups(makeGroups(items, threshold))
  local tracks = {}
  for _, group in ipairs(groups) do
    local sorted = {}
    for _, entry in ipairs(group.items) do sorted[#sorted + 1] = entry end
    table.sort(sorted, function(a, b)
      if a.position ~= b.position then return a.position < b.position end
      if a.length ~= b.length then return a.length < b.length end
      return a.name < b.name
    end)
    local lanes = {}
    for _, entry in ipairs(sorted) do
      local lane
      if entry.length <= 0 then
        lane = lanes[1]
      else
        for _, candidate in ipairs(lanes) do
          if candidate.finish <= entry.position then
            lane = candidate
            break
          end
        end
      end
      if not lane then
        lane = {items = {}, finish = -math.huge, index = #lanes + 1}
        lanes[#lanes + 1] = lane
      end
      lane.items[#lane.items + 1] = entry.item
      if entry.length > 0 then
        lane.finish = entry.position + entry.length
      end
    end
    -- Les pistes les plus remplies montent en premier dans chaque groupe.
    table.sort(lanes, function(a, b)
      if #a.items ~= #b.items then return #a.items > #b.items end
      return a.index < b.index
    end)
    group.lanes = lanes
    for i, lane in ipairs(lanes) do
      tracks[#tracks + 1] = {
        label = group.label .. (i > 1 and " (" .. i .. ")" or ""),
        items = lane.items
      }
    end
  end
  return groups, tracks
end

local function apply(selection, planned_tracks)
  if #planned_tracks == 0 then return end
  local selected = {}
  for _, track in ipairs(selection.tracks) do selected[track] = true end
  local original_depths = {}
  for i = 0, reaper.CountTracks(PROJECT) - 1 do
    local track = reaper.GetTrack(PROJECT, i)
    if not selected[track] then
      original_depths[#original_depths + 1] = {
        track = track,
        depth = reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH")
      }
    end
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  local destinations, moved, failed = {}, 0, false
  for i, plan in ipairs(planned_tracks) do
    local index = selection.first_index + i - 1
    reaper.InsertTrackAtIndex(index, true)
    local track = reaper.GetTrack(PROJECT, index)
    destinations[i] = track
    reaper.GetSetMediaTrackInfo_String(track, "P_NAME", plan.label, true)
  end
  for i, plan in ipairs(planned_tracks) do
    for _, item in ipairs(plan.items) do
      if not reaper.MoveMediaItemToTrack(item, destinations[i]) then
        failed = true
        break
      end
      moved = moved + 1
    end
    if failed then break end
  end
  if not failed then
    for i = #selection.tracks, 1, -1 do
      reaper.DeleteTrack(selection.tracks[i])
    end
    -- La suppression d'une piste fermant un dossier peut reporter sa fermeture
    -- sur une piste voisine. Restitue explicitement toute la structure initiale.
    for _, saved in ipairs(original_depths) do
      reaper.SetMediaTrackInfo_Value(saved.track, "I_FOLDERDEPTH", saved.depth)
    end
    for _, track in ipairs(destinations) do
      reaper.SetMediaTrackInfo_Value(track, "I_FOLDERDEPTH", 0)
    end
    reaper.SetMediaTrackInfo_Value(destinations[#destinations],
      "I_FOLDERDEPTH", selection.closing_depth)
    reaper.SetOnlyTrackSelected(destinations[1])
    for i = 2, #destinations do
      reaper.SetTrackSelected(destinations[i], true)
    end
  end
  reaper.PreventUIRefresh(-1)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock(string.format("Group %d items by name on %d tracks",
    moved, #planned_tracks), -1)
  if failed then
    reaper.ShowMessageBox(
      "Un item n'a pas pu être déplacé. Annule les changements avec Ctrl+Z si nécessaire.",
      TITLE, 0)
  end
end
local ctx = reaper.ImGui_CreateContext(TITLE)
local threshold = 65
local selection, selection_error = collectSelection()
if not selection then
  reaper.ShowMessageBox(selection_error, TITLE, 0)
  return
end
local groups, planned_tracks = planTracks(selection.items, threshold)
local project_state = reaper.GetProjectStateChangeCount(PROJECT)

local function loop()
  reaper.ImGui_SetNextWindowSize(ctx, 580, 500, reaper.ImGui_Cond_FirstUseEver())
  local visible, open = reaper.ImGui_Begin(ctx, TITLE, true)
  if visible then
    local current_state = reaper.GetProjectStateChangeCount(PROJECT)
    if current_state ~= project_state then
      selection, selection_error = collectSelection()
      if selection then
        groups, planned_tracks = planTracks(selection.items, threshold)
      else
        groups, planned_tracks = {}, {}
      end
      project_state = current_state
    end

    reaper.ImGui_TextWrapped(ctx,
      "Remplace un bloc de pistes consécutives du même dossier par des pistes " ..
      "regroupées selon le nom " ..
      "des items. Les chevauchements créent des pistes supplémentaires. " ..
      "Les pistes source, leurs FX et leur routage sont supprimés.")
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_SetNextItemWidth(ctx, 340)
    local changed, value = reaper.ImGui_SliderInt(ctx,
      "Similarité minimale (%)", threshold, 1, 100)
    if changed then
      threshold = value
      if selection then
        groups, planned_tracks = planTracks(selection.items, threshold)
      end
    end
    reaper.ImGui_TextDisabled(ctx,
      "100 % = noms strictement identiques ; plus bas = regroupement plus souple.")
    reaper.ImGui_TextDisabled(ctx,
      "Les numéros finaux différents restent toujours sur des pistes distinctes.")
    reaper.ImGui_Separator(ctx)
    if selection then
      reaper.ImGui_Text(ctx, string.format(
        "%d pistes remplacées → %d pistes créées (%d groupes, %d items)%s",
        #selection.tracks, #planned_tracks, #groups, #selection.items,
        selection.unnamed > 0 and
        string.format(" ; %d items sans nom conservés", selection.unnamed) or ""))
    else
      reaper.ImGui_TextWrapped(ctx, selection_error)
    end

    local child_visible = reaper.ImGui_BeginChild(ctx, "##preview", 0, -42)
    if child_visible then
      for i = 1, math.min(#groups, 100) do
        local group = groups[i]
        reaper.ImGui_TextWrapped(ctx, string.format(
          "%d. %s — %d item(s), %d piste(s)",
          i, group.label, #group.items, #group.lanes))
        if #group.names > 1 then
          for j = 2, math.min(#group.names, 8) do
            reaper.ImGui_BulletText(ctx, group.names[j])
          end
          if #group.names > 8 then
            reaper.ImGui_TextDisabled(ctx,
              string.format("... et %d autres noms", #group.names - 8))
          end
        end
      end
      if #groups > 100 then
        reaper.ImGui_TextDisabled(ctx,
          string.format("... et %d autres groupes", #groups - 100))
      end
    end
    reaper.ImGui_EndChild(ctx)

    if reaper.ImGui_Button(ctx, "Remplacer les pistes sélectionnées") then
      -- Relit la sélection au moment de l'action pour éviter des pointeurs périmés.
      selection, selection_error = collectSelection()
      if selection then
        groups, planned_tracks = planTracks(selection.items, threshold)
        apply(selection, planned_tracks)
        open = false
      else
        reaper.ShowMessageBox(selection_error, TITLE, 0)
      end
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Annuler") then open = false end
    if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
      open = false
    end
  end
  reaper.ImGui_End(ctx)
  if open then reaper.defer(loop) end
end

reaper.defer(loop)
