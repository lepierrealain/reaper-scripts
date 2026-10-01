-- @description Compact items on identical selected tracks
-- @author lepierrealain
-- @version 1.3

-- Regroupe les pistes sélectionnées sans séparer les items qui se trouvent
-- déjà sur une même piste. Les positions des items ne changent pas. Seules
-- des pistes du même dossier et aux réglages identiques sont regroupées.
-- À nombre de pistes égal, rapproche verticalement les prises de même nom,
-- en privilégiant celles qui sont aussi proches dans le temps.
-- Les pistes avec automation, receives ou lanes sont ignorées : leur
-- suppression pourrait modifier le projet malgré des réglages apparents égaux.

local PROJECT = 0

-- Champs de piste qui changent le son, le routage parent ou le comportement
-- d'enregistrement. Le nom et la taille affichée ne sont pas déterminants.
local TRACK_FIELDS = {
  "B_MUTE", "B_PHASE", "I_SOLO", "B_SOLO_DEFEAT", "I_FXEN",
  "D_VOL", "D_PAN", "D_WIDTH", "D_DUALPANL", "D_DUALPANR",
  "I_PANMODE", "D_PANLAW", "I_PANLAW_FLAGS", "I_NCHAN",
  "I_CUSTOMCOLOR", "B_MAINSEND", "C_MAINSEND_OFFS",
  "C_MAINSEND_NCH", "I_MIDIHWOUT", "I_MIDIHWOUT_SLOT",
  "I_MIDI_INPUT_CHANMAP", "I_MIDI_CTL_CHAN", "I_PERFFLAGS",
  "I_PLAY_OFFSET_FLAG", "D_PLAY_OFFSET", "C_BEATATTACHMODE",
  "I_RECARM", "I_RECINPUT", "I_RECMODE", "I_RECMODE_FLAGS",
  "I_RECMON", "I_RECMONITEMS", "B_AUTO_RECARM", "I_AUTOMODE"
}

local SEND_FIELDS = {
  "B_MUTE", "B_PHASE", "B_MONO", "D_VOL", "D_PAN", "D_PANLAW",
  "I_SENDMODE", "I_AUTOMODE", "I_SRCCHAN", "I_DSTCHAN",
  "I_MIDIFLAGS"
}

local function appendRouting(signature, track, category)
  local count = reaper.GetTrackNumSends(track, category)
  signature[#signature + 1] = tostring(count)
  for i = 0, count - 1 do
    if category == 0 then
      signature[#signature + 1] = tostring(
        reaper.GetTrackSendInfo_Value(track, category, i, "P_DESTTRACK"))
    end
    for _, field in ipairs(SEND_FIELDS) do
      signature[#signature + 1] = tostring(
        reaper.GetTrackSendInfo_Value(track, category, i, field))
    end
  end
end

-- Compare le contenu des chaînes FX sans les GUID d'instances ni la position
-- de leurs fenêtres. Les données et paramètres des plugins restent comparés.
local function fxSignature(chunk)
  local lines, depth, fx_depth = {}, 0, nil
  local found = false
  for line in (chunk .. "\n"):gmatch("(.-)\n") do
    local tag = line:match("^%s*<([%w_]+)")
    local closes = line:match("^%s*>%s*$") ~= nil
    if tag then
      if depth == 1 and tag:match("^FXCHAIN") then
        fx_depth = 2
        found = true
      end
      depth = depth + 1
    end
    if fx_depth then
      local field = line:match("^%s*([%u_]+)%s")
      if line:match("^%s*FXID%s+%b{}") then
        lines[#lines + 1] = line:gsub("%b{}", "{FX_GUID}", 1)
      elseif depth ~= fx_depth or (field ~= "SHOW" and
          field ~= "LASTSEL" and field ~= "DOCKED" and
          field ~= "FLOATPOS") then
        lines[#lines + 1] = line
      end
    end
    if closes then
      depth = depth - 1
      if fx_depth and depth < fx_depth then fx_depth = nil end
    end
  end
  if depth ~= 0 or not found then return nil end
  return table.concat(lines, "\n")
end

local function eligible(track)
  -- Une piste parent ne peut pas être supprimée. Une piste qui ferme un dossier
  -- peut participer si elle est obligatoirement conservée lors du compactage.
  if reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH") > 0 then return nil end
  if reaper.CountTrackEnvelopes(track) ~= 0 then return nil end
  if reaper.GetTrackNumSends(track, -1) ~= 0 then return nil end
  if reaper.GetMediaTrackInfo_Value(track, "I_FREEMODE") ~= 0 or
      reaper.GetMediaTrackInfo_Value(track, "I_FREEZECOUNT") ~= 0 then return nil end

  local signature = {}
  for _, field in ipairs(TRACK_FIELDS) do
    signature[#signature + 1] = tostring(reaper.GetMediaTrackInfo_Value(track, field))
  end
  appendRouting(signature, track, 0)
  appendRouting(signature, track, 1)
  local fx_count = reaper.TrackFX_GetCount(track)
  local rec_fx_count = reaper.TrackFX_GetRecCount(track)
  signature[#signature + 1] = tostring(fx_count)
  signature[#signature + 1] = tostring(rec_fx_count)
  if fx_count + rec_fx_count > 0 then
    local ok, chunk = reaper.GetTrackStateChunk(track, "", false)
    if not ok then return nil end
    local fx = fxSignature(chunk)
    if not fx then return nil end
    signature[#signature + 1] = fx
  end
  return table.concat(signature, "\0")
end

local function planGroup(group)
  if #group < 2 then return nil end

  local bundles, structural = {}, {}
  for _, track in ipairs(group) do
    if reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH") < 0 then
      structural[#structural + 1] = track
    end
    local bundle = {track = track, items = {}, intervals = {}, named = {}}
    for i = 0, reaper.CountTrackMediaItems(track) - 1 do
      local item = reaper.GetTrackMediaItem(track, i)
      local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      bundle.items[#bundle.items + 1] = item
      if len > 0 then
        bundle.intervals[#bundle.intervals + 1] = {start = pos, finish = pos + len}
      end
      local take = reaper.GetActiveTake(item)
      if take then
        local ok, name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
        if ok and name ~= "" then
          bundle.named[#bundle.named + 1] = {
            name = name, start = pos, finish = pos + len, length = len
          }
        end
      end
    end
    if #bundle.items > 0 then
      table.sort(bundle.intervals, function(a, b) return a.start < b.start end)
      bundles[#bundles + 1] = bundle
    end
  end

  local function conflicts(a, b)
    local i, j = 1, 1
    while i <= #a.intervals and j <= #b.intervals do
      local x, y = a.intervals[i], b.intervals[j]
      if x.finish <= y.start then
        i = i + 1
      elseif y.finish <= x.start then
        j = j + 1
      else
        return true
      end
    end
    return false
  end

  -- Deux pistes sont incompatibles si au moins un item de chacune se
  -- chevauche. Colorer ce graphe revient à ranger les pistes entières dans
  -- le minimum de pistes de destination.
  local n, graph, degree = #bundles, {}, {}
  for i = 1, n do graph[i], degree[i] = {}, 0 end
  for i = 1, n do
    for j = i + 1, n do
      if conflicts(bundles[i], bundles[j]) then
        graph[i][j], graph[j][i] = true, true
        degree[i], degree[j] = degree[i] + 1, degree[j] + 1
      end
    end
  end

  -- Affinité entre pistes : chaque paire d'items portant exactement le même
  -- nom compte, avec un poids plus fort si les deux sont proches dans le temps.
  local affinity, by_name = {}, {}
  for i = 1, n do
    affinity[i] = {}
    for _, entry in ipairs(bundles[i].named) do
      local list = by_name[entry.name]
      if not list then list = {}; by_name[entry.name] = list end
      list[#list + 1] = {bundle = i, start = entry.start,
        finish = entry.finish, length = entry.length}
    end
  end
  for _, list in pairs(by_name) do
    for i = 1, #list - 1 do
      local a = list[i]
      for j = i + 1, #list do
        local b = list[j]
        if a.bundle ~= b.bundle then
          local gap = math.max(0, math.max(a.start, b.start) -
            math.min(a.finish, b.finish))
          local scale = math.max(1, math.min(a.length, b.length))
          local weight = 1 / (1 + gap / scale)
          affinity[a.bundle][b.bundle] =
            (affinity[a.bundle][b.bundle] or 0) + weight
          affinity[b.bundle][a.bundle] =
            (affinity[b.bundle][a.bundle] or 0) + weight
        end
      end
    end
  end

  local function chooseVertex(colors)
    local chosen, best_saturation, best_degree = nil, -1, -1
    for i = 1, n do
      if not colors[i] then
        local seen, saturation = {}, 0
        for j = 1, n do
          local color = colors[j]
          if graph[i][j] and color and not seen[color] then
            seen[color], saturation = true, saturation + 1
          end
        end
        if saturation > best_saturation or
            (saturation == best_saturation and degree[i] > best_degree) then
          chosen, best_saturation, best_degree = i, saturation, degree[i]
        end
      end
    end
    return chosen
  end

  local function canUse(colors, vertex, color)
    for j = 1, n do
      if graph[vertex][j] and colors[j] == color then return false end
    end
    return true
  end

  -- DSATUR donne d'abord une solution rapide. Pour un groupe raisonnable,
  -- une recherche bornée tente ensuite de réduire encore le nombre de pistes.
  local best_colors, best_count = {}, 0
  for _ = 1, n do
    local vertex = chooseVertex(best_colors)
    local color, best_affinity = nil, -1
    for candidate = 1, best_count do
      if canUse(best_colors, vertex, candidate) then
        local score = 0
        for j = 1, n do
          if best_colors[j] == candidate then
            score = score + (affinity[vertex][j] or 0)
          end
        end
        if score > best_affinity then
          color, best_affinity = candidate, score
        end
      end
    end
    if not color then color = best_count + 1 end
    if color > best_count then best_count = color end
    best_colors[vertex] = color
  end
  -- Le critère de nom ne doit jamais coûter une piste par rapport au
  -- placement glouton sans préférence de nom.
  local plain_colors, plain_count = {}, 0
  for _ = 1, n do
    local vertex = chooseVertex(plain_colors)
    local color = 1
    while color <= plain_count and not canUse(plain_colors, vertex, color) do
      color = color + 1
    end
    if color > plain_count then plain_count = color end
    plain_colors[vertex] = color
  end
  if plain_count < best_count then
    best_colors, best_count = plain_colors, plain_count
  end
  if n > 1 and n <= 24 and best_count > 1 then
    local colors, steps = {}, 0
    local function search(assigned, used)
      if used >= best_count or steps >= 20000 then return end
      if assigned == n then
        best_count = used
        for i = 1, n do best_colors[i] = colors[i] end
        return
      end
      steps = steps + 1
      local vertex = chooseVertex(colors)
      for color = 1, math.min(used + 1, best_count - 1) do
        if canUse(colors, vertex, color) then
          colors[vertex] = color
          search(assigned + 1, math.max(used, color))
          colors[vertex] = nil
        end
      end
    end
    search(0, 0)
  end

  -- À nombre de pistes fixé, rapprocher les lots de même nom en déplaçant
  -- un lot entier vers une autre couleur compatible si l'affinité augmente.
  local color_sizes = {}
  for i = 1, n do
    local color = best_colors[i]
    color_sizes[color] = (color_sizes[color] or 0) + 1
  end
  for _ = 1, n do
    local best_vertex, best_color, best_gain = nil, nil, 0
    for i = 1, n do
      local old = best_colors[i]
      if color_sizes[old] > 1 then
        local current = 0
        for j = 1, n do
          if j ~= i and best_colors[j] == old then
            current = current + (affinity[i][j] or 0)
          end
        end
        for color = 1, best_count do
          if color ~= old and canUse(best_colors, i, color) then
            local candidate = 0
            for j = 1, n do
              if best_colors[j] == color then
                candidate = candidate + (affinity[i][j] or 0)
              end
            end
            local gain = candidate - current
            if gain > best_gain + 1e-9 then
              best_vertex, best_color, best_gain = i, color, gain
            end
          end
        end
      end
    end
    if not best_vertex then break end
    local old = best_colors[best_vertex]
    best_colors[best_vertex] = best_color
    color_sizes[old] = color_sizes[old] - 1
    color_sizes[best_color] = color_sizes[best_color] + 1
  end

  local class_affinity, cross_affinity = {}, 0
  for color = 1, best_count do class_affinity[color] = {} end
  for i = 1, n do
    for j = i + 1, n do
      local a, b = best_colors[i], best_colors[j]
      local weight = affinity[i][j] or 0
      if a ~= b and weight > 0 then
        class_affinity[a][b] = (class_affinity[a][b] or 0) + weight
        class_affinity[b][a] = (class_affinity[b][a] or 0) + weight
        cross_affinity = cross_affinity + weight
      end
    end
  end

  local keep, needed = {}, math.max(1, best_count, #structural)
  for _, track in ipairs(structural) do keep[track] = true end
  if cross_affinity > 1e-9 and best_count > 1 then
    -- Les pistes conservées sont rapprochées physiquement avant de choisir
    -- quelle couleur occupera quelle piste. Les fermetures de dossier restent.
    if #structural == 0 then
      local best_start, best_span, best_items = 1, math.huge, -1
      for first = 1, #group - needed + 1 do
        local last = first + needed - 1
        local span = reaper.GetMediaTrackInfo_Value(group[last], "IP_TRACKNUMBER") -
          reaper.GetMediaTrackInfo_Value(group[first], "IP_TRACKNUMBER")
        local item_count = 0
        for i = first, last do
          item_count = item_count + reaper.CountTrackMediaItems(group[i])
        end
        if span < best_span or (span == best_span and item_count > best_items) then
          best_start, best_span, best_items = first, span, item_count
        end
      end
      for i = best_start, best_start + needed - 1 do keep[group[i]] = true end
    else
      local kept_count = #structural
      while kept_count < needed do
        local best_track, best_span, best_items = nil, math.huge, -1
        for _, candidate in ipairs(group) do
          if not keep[candidate] then
            local lo, hi = math.huge, -math.huge
            for track in pairs(keep) do
              local number = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")
              lo, hi = math.min(lo, number), math.max(hi, number)
            end
            local number = reaper.GetMediaTrackInfo_Value(candidate, "IP_TRACKNUMBER")
            local span = math.max(hi, number) - math.min(lo, number)
            local item_count = reaper.CountTrackMediaItems(candidate)
            if span < best_span or (span == best_span and item_count > best_items) then
              best_track, best_span, best_items = candidate, span, item_count
            end
          end
        end
        keep[best_track] = true
        kept_count = kept_count + 1
      end
    end
  else
    -- Sans affinité entre couleurs, conserver en priorité les pistes portant
    -- le plus d'items afin de limiter les déplacements.
    local kept_count = 0
    for _ in pairs(keep) do kept_count = kept_count + 1 end
    while kept_count < needed do
      local represented = {}
      for i, bundle in ipairs(bundles) do
        if keep[bundle.track] then represented[best_colors[i]] = true end
      end
      local choice, best_new_color, best_items = nil, -1, -1
      for i, bundle in ipairs(bundles) do
        if not keep[bundle.track] then
          local new_color = represented[best_colors[i]] and 0 or 1
          if new_color > best_new_color or
              (new_color == best_new_color and #bundle.items > best_items) then
            choice, best_new_color, best_items =
              bundle.track, new_color, #bundle.items
          end
        end
      end
      if not choice then
        for _, track in ipairs(group) do
          if not keep[track] then choice = track; break end
        end
      end
      keep[choice] = true
      kept_count = kept_count + 1
    end
  end

  local kept, positions = {}, {}
  local removed_before = 0
  for _, track in ipairs(group) do
    if keep[track] then
      kept[#kept + 1] = track
      positions[#positions + 1] =
        reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") - removed_before
    else
      removed_before = removed_before + 1
    end
  end

  local stay, total_items = {}, 0
  for color = 1, best_count do stay[color] = {} end
  for i, bundle in ipairs(bundles) do
    local color = best_colors[i]
    total_items = total_items + #bundle.items
    for slot, track in ipairs(kept) do
      if bundle.track == track then
        stay[color][slot] = #bundle.items
      end
    end
  end

  local function layoutScore(mapping)
    local visual, unchanged = 0, 0
    for a = 1, best_count do
      unchanged = unchanged + (stay[a][mapping[a]] or 0)
      for b = a + 1, best_count do
        visual = visual + (class_affinity[a][b] or 0) *
          math.abs(positions[mapping[a]] - positions[mapping[b]])
      end
    end
    return visual, total_items - unchanged
  end

  local mapping, occupied = {}, {}
  for color = 1, best_count do
    local choice, most_staying = nil, -1
    for slot = 1, #kept do
      if not occupied[slot] and (stay[color][slot] or 0) > most_staying then
        choice, most_staying = slot, stay[color][slot] or 0
      end
    end
    mapping[color], occupied[choice] = choice, true
  end
  local function copyMapping(source)
    local copy = {}
    for color = 1, best_count do copy[color] = source[color] end
    return copy
  end
  local best_mapping = copyMapping(mapping)
  local best_visual, best_moved = layoutScore(mapping)
  local function consider(candidate)
    local visual, moved = layoutScore(candidate)
    if visual < best_visual - 1e-9 or
        (math.abs(visual - best_visual) <= 1e-9 and moved < best_moved) then
      best_visual, best_moved = visual, moved
      for color = 1, best_count do best_mapping[color] = candidate[color] end
      return true
    end
    return false
  end

  if best_count <= 8 and #kept <= 8 then
    local candidate, used_slots = {}, {}
    local function arrange(color)
      if color > best_count then consider(candidate); return end
      for slot = 1, #kept do
        if not used_slots[slot] then
          candidate[color], used_slots[slot] = slot, true
          arrange(color + 1)
          used_slots[slot] = nil
        end
      end
    end
    arrange(1)
  else
    -- Pour de grands groupes, améliorer la disposition par échanges locaux.
    for _ = 1, best_count do
      local improved = false
      for a = 1, best_count do
        for b = a + 1, best_count do
          local candidate = copyMapping(best_mapping)
          candidate[a], candidate[b] = candidate[b], candidate[a]
          if consider(candidate) then improved = true end
        end
        local occupied_now = {}
        for color = 1, best_count do
          occupied_now[best_mapping[color]] = true
        end
        for slot = 1, #kept do
          if not occupied_now[slot] then
            local candidate = copyMapping(best_mapping)
            candidate[a] = slot
            if consider(candidate) then improved = true end
          end
        end
      end
      if not improved then break end
    end
  end

  local destination = {}
  for color = 1, best_count do
    destination[color] = kept[best_mapping[color]]
  end

  if #kept == #group then
    local current_visual = 0
    for i = 1, n do
      for j = i + 1, n do
        current_visual = current_visual + (affinity[i][j] or 0) *
          math.abs(reaper.GetMediaTrackInfo_Value(bundles[i].track, "IP_TRACKNUMBER") -
            reaper.GetMediaTrackInfo_Value(bundles[j].track, "IP_TRACKNUMBER"))
      end
    end
    if best_visual >= current_visual - 1e-9 then return nil end
  end

  local plan = {moves = {}, remove = {}}
  for i, bundle in ipairs(bundles) do
    local dest = destination[best_colors[i]]
    if dest ~= bundle.track then
      for _, item in ipairs(bundle.items) do
        plan.moves[#plan.moves + 1] = {item = item, destination = dest}
      end
    end
  end
  for i = #group, 1, -1 do
    if not keep[group[i]] then plan.remove[#plan.remove + 1] = group[i] end
  end
  if #plan.moves == 0 and #plan.remove == 0 then return nil end
  return plan
end

local function main()
  local count = reaper.CountSelectedTracks(PROJECT)
  if count < 2 then
    reaper.ShowMessageBox("Sélectionne au moins deux pistes.",
      "Compact selected tracks", 0)
    return
  end

  local groups, keys = {}, {}
  local eligible_count = 0
  for i = 0, count - 1 do
    local track = reaper.GetSelectedTrack(PROJECT, i)
    local signature = eligible(track)
    if signature then
      eligible_count = eligible_count + 1
      local parent = reaper.GetParentTrack(track)
      local key = tostring(parent) .. "\0" .. signature
      if not groups[key] then
        groups[key] = {}
        keys[#keys + 1] = key
      end
      groups[key][#groups[key] + 1] = track
    end
  end

  local plans = {}
  local compatible = false
  for _, key in ipairs(keys) do
    if #groups[key] >= 2 then compatible = true end
    local plan = planGroup(groups[key])
    if plan then plans[#plans + 1] = plan end
  end
  if #plans == 0 then
    local reason
    if eligible_count < 2 then
      reason = "Moins de deux pistes sélectionnées sont éligibles (piste parent, automation, receive, lanes ou piste gelée)."
    elseif not compatible then
      reason = "Aucune paire de pistes sélectionnées n'a les mêmes réglages et le même dossier."
    else
      reason = "Aucune piste à supprimer ni aucun rapprochement utile pour les noms identiques."
    end
    reaper.ShowMessageBox(reason, "Compact selected tracks", 0)
    return
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  local moved, deleted = 0, 0
  local failed = false
  for _, plan in ipairs(plans) do
    for _, move in ipairs(plan.moves) do
      if not reaper.MoveMediaItemToTrack(move.item, move.destination) then
        failed = true
        break
      end
      moved = moved + 1
    end
    if failed then break end
    for _, track in ipairs(plan.remove) do
      reaper.DeleteTrack(track)
      deleted = deleted + 1
    end
  end
  reaper.PreventUIRefresh(-1)
  if moved > 0 or deleted > 0 then
    reaper.UpdateArrange()
    reaper.TrackList_AdjustWindows(false)
  end
  reaper.Undo_EndBlock(string.format(
    "Compact selected tracks (%d items moved, %d tracks removed)",
    moved, deleted), -1)
  if failed then
    reaper.ShowMessageBox(
      "Un item n'a pas pu être déplacé. Les changements déjà faits peuvent être annulés avec Ctrl+Z.",
      "Compact selected tracks", 0)
  end
end

main()
