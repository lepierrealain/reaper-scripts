-- @description Compact items on identical selected tracks
-- @author lepierrealain
-- @version 1.3

-- Compacte les groupes continus des pistes sélectionnées vers le minimum de
-- pistes, en privilégiant la destination disponible la plus haute. Les items
-- qui se chevauchent ou se touchent sur une même piste restent ensemble.
-- Les positions temporelles ne changent pas. Seules des pistes du même dossier
-- et aux réglages identiques (hors couleur) sont regroupées.
-- Les pistes avec automation, receives ou lanes sont ignorées : leur
-- suppression pourrait modifier le projet malgré des réglages apparents égaux.

local PROJECT = 0

-- Champs de piste qui changent le son, le routage parent ou le comportement
-- d'enregistrement. Le nom, la couleur et la taille affichée sont ignorés.
local TRACK_FIELDS = {
  "B_MUTE", "B_PHASE", "I_SOLO", "B_SOLO_DEFEAT", "I_FXEN",
  "D_VOL", "D_PAN", "D_WIDTH", "D_DUALPANL", "D_DUALPANR",
  "I_PANMODE", "D_PANLAW", "I_PANLAW_FLAGS", "I_NCHAN",
  "B_MAINSEND", "C_MAINSEND_OFFS",
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
  table.sort(group, function(a, b)
    return reaper.GetMediaTrackInfo_Value(a, "IP_TRACKNUMBER") <
      reaper.GetMediaTrackInfo_Value(b, "IP_TRACKNUMBER")
  end)

  local bundles, keep, structural_count = {}, {}, 0
  for track_order, track in ipairs(group) do
    if reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH") < 0 then
      keep[track] = true
      structural_count = structural_count + 1
    end
    local entries = {}
    for i = 0, reaper.CountTrackMediaItems(track) - 1 do
      local item = reaper.GetTrackMediaItem(track, i)
      local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      entries[#entries + 1] = {
        item = item, start = pos, finish = pos + len, order = i
      }
    end
    table.sort(entries, function(a, b)
      if a.start ~= b.start then return a.start < b.start end
      return a.order < b.order
    end)

    -- Garder ensemble chaque chaîne continue d'une piste, y compris les
    -- contacts exacts et les chevauchements transitifs ou imbriqués.
    local bundle
    for _, entry in ipairs(entries) do
      if not bundle or entry.start > bundle.finish then
        bundle = {
          track = track, track_order = track_order, order = entry.order,
          start = entry.start, finish = entry.finish, items = {}
        }
        bundles[#bundles + 1] = bundle
      end
      bundle.items[#bundle.items + 1] = entry.item
      bundle.finish = math.max(bundle.finish, entry.finish)
    end
  end
  table.sort(bundles, function(a, b)
    if a.start ~= b.start then return a.start < b.start end
    if a.track_order ~= b.track_order then
      return a.track_order < b.track_order
    end
    return a.order < b.order
  end)

  -- Pour des intervalles continus triés, réutiliser la première destination
  -- libre garantit le minimum de pistes et le placement le plus haut.
  -- Les groupes de durée nulle n'occupent aucun intervalle temporel.
  local finishes = {}
  for _, bundle in ipairs(bundles) do
    local slot = 1
    if bundle.finish > bundle.start then
      while finishes[slot] and finishes[slot] > bundle.start do
        slot = slot + 1
      end
      finishes[slot] = bundle.finish
    elseif not finishes[1] then
      finishes[1] = -math.huge
    end
    bundle.slot = slot
  end

  -- Les fermetures de dossier restent obligatoirement présentes. Compléter
  -- le minimum nécessaire avec les pistes compatibles les plus hautes.
  local needed = math.max(1, #finishes, structural_count)
  local kept_count = structural_count
  for _, track in ipairs(group) do
    if kept_count >= needed then break end
    if not keep[track] then
      keep[track] = true
      kept_count = kept_count + 1
    end
  end
  local kept = {}
  for _, track in ipairs(group) do
    if keep[track] then kept[#kept + 1] = track end
  end

  local plan = {moves = {}, remove = {}}
  for _, bundle in ipairs(bundles) do
    local dest = kept[bundle.slot]
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
      reason = "Aucune piste à supprimer ni aucun groupe à déplacer vers une piste plus haute."
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
