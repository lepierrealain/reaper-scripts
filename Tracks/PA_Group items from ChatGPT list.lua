-- @description Group selected items from a ChatGPT list
-- @author lepierrealain
-- @version 1.2
-- @requires ReaImGui
-- @about
--   Exports selected take names for classification, then creates folders and
--   nested subfolders above the highest selected source track. Items keep
--   their timeline positions and existing overlaps on the same source track.

local PROJECT = 0
local TITLE = "Group items from ChatGPT list"

if not reaper.ImGui_CreateContext then
  reaper.ShowMessageBox("Ce script nécessite ReaImGui (disponible via ReaPack).", TITLE, 0)
  return
end

local function trim(value)
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function displayList(values, limit)
  local shown = {}
  for i = 1, math.min(#values, limit or 5) do shown[#shown + 1] = values[i] end
  if #values > #shown then shown[#shown + 1] = "..." end
  return table.concat(shown, ", ")
end

local function capture()
  local count = reaper.CountSelectedMediaItems(PROJECT)
  if count == 0 then return nil, "Sélectionne d'abord les items à classer." end

  local actual_names = {}
  for i = 0, count - 1 do
    local take = reaper.GetActiveTake(reaper.GetSelectedMediaItem(PROJECT, i))
    if take then actual_names[trim(reaper.GetTakeName(take))] = true end
  end
  local entries, names, by_name, unnamed = {}, {}, {}, 0
  for i = 0, count - 1 do
    local item = reaper.GetSelectedMediaItem(PROJECT, i)
    local take = reaper.GetActiveTake(item)
    local name = take and trim(reaper.GetTakeName(take)) or ""
    if name == "" then
      repeat
        unnamed = unnamed + 1
        name = "[Item sans nom " .. unnamed .. "]"
      until not actual_names[name]
    end
    if name:find(" / ", 1, true) or name:find("\n", 1, true) or
        name:find("\r", 1, true) then
      return nil, "Le nom « " .. name .. " » contient un séparateur ou un retour à la ligne. Renomme cet item avant l'export."
    end
    local track = reaper.GetMediaItemTrack(item)
    local position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local entry = {item = item, name = name, track = track,
      position = position, finish = position + length}
    entries[#entries + 1] = entry
    if not by_name[name] then
      by_name[name] = {}
      names[#names + 1] = name
    end
    by_name[name][#by_name[name] + 1] = entry
  end

  table.sort(entries, function(a, b)
    local at = reaper.GetMediaTrackInfo_Value(a.track, "IP_TRACKNUMBER")
    local bt = reaper.GetMediaTrackInfo_Value(b.track, "IP_TRACKNUMBER")
    if at ~= bt then return at < bt end
    if a.position ~= b.position then return a.position < b.position end
    return a.name < b.name
  end)

  -- Names linked by an existing overlap must be placed in the same folder.
  local parent = {}
  for _, name in ipairs(names) do parent[name] = name end
  local function root(name)
    if parent[name] ~= name then parent[name] = root(parent[name]) end
    return parent[name]
  end
  local function unite(a, b)
    local ra, rb = root(a), root(b)
    if ra ~= rb then parent[rb] = ra end
  end
  local previous_track, end_of_component, first_name
  for _, entry in ipairs(entries) do
    if entry.track ~= previous_track or entry.position >= end_of_component then
      first_name, end_of_component = entry.name, entry.finish
    elseif entry.finish > entry.position then
      unite(first_name, entry.name)
      end_of_component = math.max(end_of_component, entry.finish)
    end
    previous_track = entry.track
  end

  local components, component_by_root = {}, {}
  for _, entry in ipairs(entries) do
    local key = root(entry.name)
    local component = component_by_root[key]
    if not component then
      component = {names = {}, seen = {}}
      component_by_root[key] = component
      components[#components + 1] = component
    end
    if not component.seen[entry.name] then
      component.seen[entry.name] = true
      component.names[#component.names + 1] = entry.name
    end
  end
  local lines = {}
  for _, component in ipairs(components) do
    lines[#lines + 1] = table.concat(component.names, " / ")
  end
  return {entries = entries, names = names, by_name = by_name,
    root = root, text = table.concat(lines, "\n"),
    state = reaper.GetProjectStateChangeCount(PROJECT),
    project = reaper.EnumProjects(-1)}
end

local function chatPrompt(list)
  return table.concat({
    "Voici les noms des fichiers à classer dans REAPER.",
    "Je t'expliquerai moi-même comment je souhaite les catégoriser. Si je n'ai pas encore donné ces consignes, attends-les avant de proposer le classement.",
    "",
    "Quand tu réponds avec le classement, utilise uniquement des lignes sous cette forme :",
    "Dossier : fichier.wav / autre.wav",
    "Dossier > Sous-dossier : fichier.wav / autre.wav",
    "Dossier > Sous-dossier > Niveau suivant : fichier.wav",
    "",
    "Le signe > sépare les niveaux de dossiers. Le signe / sépare les noms de fichiers sur une ligne ; écris-le avec un espace de chaque côté. Crée autant de niveaux de dossiers que nécessaire, selon mes consignes. Un dossier peut aussi contenir directement des fichiers et des sous-dossiers.",
    "Reprends chaque nom exactement comme dans la liste, une seule fois, sans en inventer ni en oublier. Les noms réunis par / dans la liste ci-dessous correspondent à des items déjà superposés : garde-les dans le même dossier. N'utilise pas > dans les noms des dossiers.",
    "Réponds uniquement avec le classement, sans introduction, puces ni bloc de code.",
    "",
    "Liste des fichiers :",
    list
  }, "\n")
end

local function splitPath(label, line_number)
  local parts, start = {}, 1
  while true do
    local first, last = label:find(">", start, true)
    local part = trim(first and label:sub(start, first - 1) or label:sub(start))
    if part == "" then
      return nil, "Ligne " .. line_number .. " : chemin de dossier invalide. Sépare les niveaux avec « > »."
    end
    parts[#parts + 1] = part
    if not first then break end
    start = last + 1
  end
  return parts
end

local function parse(text, snapshot)
  local roots, by_root, assigned, component_path = {}, {}, {}, {}
  local lines = 0
  for raw in (text:gsub("\r\n", "\n"):gsub("\r", "\n") .. "\n"):gmatch("(.-)\n") do
    lines = lines + 1
    local line = trim(raw)
    if line ~= "" and not line:match("^```") then
      line = trim(line:gsub("^%s*[%*%-]%s+", "")
        :gsub("^%s*%d+[%.%)]%s+", ""))
      local label, contents = line:match("^(.-)%s*:%s*(.+)$")
      if not label or trim(label) == "" then
        return nil, "Ligne " .. lines .. " : format attendu « Dossier > Sous-dossier : fichier.wav / autre.wav »."
      end
      label, contents = trim(label), trim(contents)
      local parts, path_error = splitPath(label, lines)
      if not parts then return nil, path_error end
      local path = table.concat(parts, " > ")
      if contents:sub(1, 1) == "/" or contents:sub(-1) == "/" then
        return nil, "Ligne " .. lines .. " : séparateur / sans nom de fichier."
      end
      local children, by_name, folder = roots, by_root, nil
      for _, part in ipairs(parts) do
        folder = by_name[part]
        if not folder then
          folder = {label = part, entries = {}, children = {}, by_name = {}}
          by_name[part] = folder
          children[#children + 1] = folder
        end
        children, by_name = folder.children, folder.by_name
      end
      local padded = contents .. " / "
      for name in padded:gmatch("(.-) / ") do
        name = trim(name)
        if name == "" then
          return nil, "Ligne " .. lines .. " : nom de fichier vide."
        end
        if not snapshot.by_name[name] then
          return nil, "Ligne " .. lines .. " : nom introuvable dans l'export : « " .. name .. " »."
        end
        if assigned[name] then
          return nil, "Le nom « " .. name .. " » apparaît plusieurs fois."
        end
        assigned[name] = true
        for _, entry in ipairs(snapshot.by_name[name]) do
          folder.entries[#folder.entries + 1] = entry
        end
        local component = snapshot.root(name)
        if component_path[component] and component_path[component] ~= path then
          return nil, "Les items « " .. name .. " » se chevauchent déjà avec des items du dossier « " ..
            component_path[component] .. " ». Mets leurs noms dans le même dossier."
        end
        component_path[component] = path
      end
    end
  end
  if #roots == 0 then return nil, "Colle au moins une ligne de classement." end
  local missing = {}
  for _, name in ipairs(snapshot.names) do
    if not assigned[name] then missing[#missing + 1] = name end
  end
  if #missing > 0 then
    return nil, "Noms manquants (" .. #missing .. ") : " .. displayList(missing, 5)
  end
  return roots
end

local function planLanes(entries)
  -- Build indivisible intervals from the overlaps on each source track.
  local sorted = {}
  for _, entry in ipairs(entries) do sorted[#sorted + 1] = entry end
  table.sort(sorted, function(a, b)
    if a.track ~= b.track then
      return reaper.GetMediaTrackInfo_Value(a.track, "IP_TRACKNUMBER") <
        reaper.GetMediaTrackInfo_Value(b.track, "IP_TRACKNUMBER")
    end
    if a.position ~= b.position then return a.position < b.position end
    return a.finish < b.finish
  end)
  local bundles, bundle, previous_track = {}, nil, nil
  for _, entry in ipairs(sorted) do
    if entry.track ~= previous_track or not bundle or entry.position >= bundle.finish then
      bundle = {position = entry.position, finish = entry.finish, items = {}}
      bundles[#bundles + 1] = bundle
    else
      bundle.finish = math.max(bundle.finish, entry.finish)
    end
    bundle.items[#bundle.items + 1] = entry.item
    previous_track = entry.track
  end
  table.sort(bundles, function(a, b)
    if a.position ~= b.position then return a.position < b.position end
    return a.finish < b.finish
  end)

  local lanes = {}
  for _, block in ipairs(bundles) do
    local chosen, latest_end
    if block.finish <= block.position then
      chosen = lanes[1]
    else
      for _, lane in ipairs(lanes) do
        if lane.finish <= block.position and
            (not latest_end or lane.finish > latest_end) then
          chosen, latest_end = lane, lane.finish
        end
      end
    end
    if not chosen then
      chosen = {finish = -math.huge, items = {}}
      lanes[#lanes + 1] = chosen
    end
    for _, item in ipairs(block.items) do
      chosen.items[#chosen.items + 1] = item
    end
    chosen.finish = math.max(chosen.finish, block.finish)
  end
  return lanes
end

local function apply(roots)
  local plans, folder_count, lane_count, total_items = {}, 0, 0, 0
  local insert_index = reaper.CountTracks(PROJECT)
  local function appendFolder(folder, depth)
    folder_count = folder_count + 1
    plans[#plans + 1] = {label = folder.label, depth = depth}
    if #folder.entries > 0 then
      for _, entry in ipairs(folder.entries) do
        insert_index = math.min(insert_index,
          reaper.GetMediaTrackInfo_Value(entry.track, "IP_TRACKNUMBER") - 1)
      end
      local lanes = planLanes(folder.entries)
      total_items = total_items + #folder.entries
      for i, lane in ipairs(lanes) do
        lane_count = lane_count + 1
        plans[#plans + 1] = {label = folder.label ..
          (i > 1 and " (" .. i .. ")" or ""), depth = depth + 1,
          lane = lane}
      end
    end
    for _, child in ipairs(folder.children) do
      appendFolder(child, depth + 1)
    end
  end
  for _, folder in ipairs(roots) do appendFolder(folder, 0) end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  local destinations, index = {}, insert_index
  for i, plan in ipairs(plans) do
    reaper.InsertTrackAtIndex(index, true)
    local track = reaper.GetTrack(PROJECT, index)
    reaper.GetSetMediaTrackInfo_String(track, "P_NAME", plan.label, true)
    local next_depth = plans[i + 1] and plans[i + 1].depth or 0
    reaper.SetMediaTrackInfo_Value(track, "I_FOLDERDEPTH",
      next_depth - plan.depth)
    if plan.lane then
      destinations[#destinations + 1] = {track = track, lane = plan.lane}
    end
    index = index + 1
  end
  local moved, failed = 0, false
  for _, destination in ipairs(destinations) do
    for _, item in ipairs(destination.lane.items) do
      if not reaper.MoveMediaItemToTrack(item, destination.track) then
        failed = true
        break
      end
      moved = moved + 1
    end
    if failed then break end
  end
  reaper.PreventUIRefresh(-1)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock(string.format("Group %d items in %d folders and %d tracks",
    moved, folder_count, lane_count), -1)
  if failed then
    return nil, "Un item n'a pas pu être déplacé. Annule les changements avec Ctrl+Z."
  end
  return string.format("%d items placés dans %d dossiers et %d pistes.",
    total_items, folder_count, lane_count)
end

local ctx = reaper.ImGui_CreateContext(TITLE)
local snapshot, export_text, response_text, message = nil, "", "", ""

local function loop()
  reaper.ImGui_SetNextWindowSize(ctx, 760, 690, reaper.ImGui_Cond_FirstUseEver())
  local visible, open = reaper.ImGui_Begin(ctx, TITLE, true)
  if visible then
    reaper.ImGui_TextWrapped(ctx,
      "1. Sélectionne les items, puis récupère la liste. Les noms séparés par / " ..
      "correspondent à des items déjà superposés sur une même piste.")
    if reaper.ImGui_Button(ctx, "Récupérer la liste des items sélectionnés") then
      local error
      snapshot, error = capture()
      export_text = snapshot and snapshot.text or ""
      message = snapshot and string.format("%d items, %d noms distincts capturés.",
        #snapshot.entries, #snapshot.names) or error
    end
    if snapshot then
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_Button(ctx, "Copier la liste et le prompt") then
        reaper.ImGui_SetClipboardText(ctx, chatPrompt(export_text))
        message = "Prompt et liste copiés dans le presse-papiers."
      end
    end
    reaper.ImGui_InputTextMultiline(ctx, "##export", export_text, -1, 175,
      reaper.ImGui_InputTextFlags_ReadOnly())
    reaper.ImGui_TextWrapped(ctx,
      "2. Copie le prompt et la liste dans ChatGPT, puis explique-lui comment tu veux " ..
      "catégoriser les fichiers. Le format « Dossier > Sous-dossier : fichier.wav / " ..
      "autre.wav » permet de créer autant de sous-dossiers que nécessaire.")
    reaper.ImGui_TextWrapped(ctx,
      "3. Colle ici le classement reçu. Les nouvelles pistes seront placées " ..
      "au-dessus de la piste la plus haute des items capturés. Les items " ..
      "garderont leur position dans le temps.")
    local changed, value = reaper.ImGui_InputTextMultiline(ctx,
      "##classification", response_text, -1, 205)
    if changed then response_text = value end
    if reaper.ImGui_Button(ctx, "Créer les dossiers et ranger les items") then
      if not snapshot then
        message = "Récupère d'abord la liste des items sélectionnés."
      elseif reaper.EnumProjects(-1) ~= snapshot.project or
          reaper.GetProjectStateChangeCount(PROJECT) ~= snapshot.state then
        message = "Le projet a changé depuis l'export. Récupère à nouveau la liste avant de ranger les items."
      else
        local groups, error = parse(response_text, snapshot)
        if not groups then
          message = error
        else
          local result, apply_error = apply(groups)
          message = result or apply_error
          if result then snapshot = nil; open = false end
        end
      end
    end
    if message ~= "" then reaper.ImGui_TextWrapped(ctx, message) end
    if reaper.ImGui_Button(ctx, "Fermer") then open = false end
    if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then open = false end
  end
  reaper.ImGui_End(ctx)
  if open then reaper.defer(loop) end
end

reaper.defer(loop)
