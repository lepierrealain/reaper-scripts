-- @description Duplicate track (sans items, renommage auto)
-- @author lepierrealain
-- @version 1.0

-- Duplique la ou les pistes sélectionnées :
--  - les items ne sont pas repris sur les duplicata
--  - si des automations existent, demande s'il faut les dupliquer ou les supprimer
--  - si des items sont sélectionnés sur les pistes source, propose de les
--    déplacer sur les nouvelles pistes
--  - sélection consécutive : les duplicata sont placés à la suite du bloc ;
--    sinon chaque duplicata suit sa piste source
--  - un nom se terminant par un numéro est incrémenté (padding conservé)

local DUPLICATE_TRACKS = 40062  -- Track: Duplicate tracks

-- true si `track` porte de l'automation réelle (points ou automation items)
local function trackHasAutomation(track)
  for i = 0, reaper.CountTrackEnvelopes(track) - 1 do
    local env = reaper.GetTrackEnvelope(track, i)
    if reaper.CountEnvelopePoints(env) > 0 or reaper.CountAutomationItems(env) > 0 then
      return true
    end
  end
  return false
end

-- Liste des items sélectionnés sur `track`
local function selectedItemsOnTrack(track)
  local items = {}
  for i = 0, reaper.CountTrackMediaItems(track) - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    if reaper.GetMediaItemInfo_Value(item, "B_UISEL") == 1 then
      items[#items + 1] = item
    end
  end
  return items
end

-- Ouverture d'un bloc d'enveloppe dans un chunk (<VOLENV2, <PARMENV, <AUXVOLENV...).
-- PROGRAMENV (modulation de paramètre) est conservé : ce n'est pas de
-- l'automation timeline.
local function isEnvBlockStart(line)
  local name = line:match("^%s*<([%u%d_]+)")
  return name ~= nil and name ~= "PROGRAMENV" and name:find("ENV", 1, true) ~= nil
end

-- Retire tous les blocs d'enveloppe du chunk de piste (y compris les PARMENV
-- imbriqués dans le FXCHAIN)
local function stripEnvelopes(chunk)
  local out, skip = {}, 0
  for line in (chunk .. "\n"):gmatch("(.-)\n") do
    if skip > 0 then
      local t = line:match("^%s*(.-)%s*$")
      if t:sub(1, 1) == "<" then
        skip = skip + 1
      elseif t == ">" then
        skip = skip - 1
      end
    elseif isEnvBlockStart(line) then
      skip = 1
    else
      out[#out + 1] = line
    end
  end
  return table.concat(out, "\n")
end

-- Incrémente le numéro final du nom de la piste, s'il existe ("Gtr 09" → "Gtr 10")
local function incrementTrailingNumber(track)
  local _, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
  local base, num = name:match("^(.-)(%d+)$")
  if not num then return end
  local new_name = string.format("%s%0" .. #num .. "d", base, tonumber(num) + 1)
  reaper.GetSetMediaTrackInfo_String(track, "P_NAME", new_name, true)
end

local function main()
  local count = reaper.CountSelectedTracks(0)
  if count == 0 then
    reaper.ShowMessageBox("No track selected.", "Duplicate track", 0)
    return
  end

  -- GetSelectedTrack renvoie les pistes dans l'ordre du projet
  local sources = {}
  for i = 0, count - 1 do
    sources[#sources + 1] = reaper.GetSelectedTrack(0, i)
  end

  local first_num = reaper.GetMediaTrackInfo_Value(sources[1], "IP_TRACKNUMBER")
  local last_num  = reaper.GetMediaTrackInfo_Value(sources[#sources], "IP_TRACKNUMBER")
  local consecutive = (last_num - first_num + 1 == #sources)

  -- Automations : dupliquer ou supprimer ?
  local keep_env = true
  for _, track in ipairs(sources) do
    if trackHasAutomation(track) then
      local ret = reaper.ShowMessageBox(
        "Dupliquer les automations sur les nouvelles pistes ?",
        "Duplicate track", 4)
      keep_env = (ret == 6)
      break
    end
  end

  -- Items sélectionnés sur les pistes source : les déplacer sur les duplicata ?
  local items_by_source = {}
  local has_selected_items = false
  for i, track in ipairs(sources) do
    items_by_source[i] = selectedItemsOnTrack(track)
    if #items_by_source[i] > 0 then has_selected_items = true end
  end

  local move_items = false
  if has_selected_items then
    local ret = reaper.ShowMessageBox(
      "Déplacer les items sélectionnés sur les nouvelles pistes ?",
      "Duplicate track", 4)
    move_items = (ret == 6)
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  -- Duplication via l'action native : FX, sends, routing et GUID sont gérés.
  -- Sélection consécutive : une seule passe, REAPER place le bloc dupliqué
  -- après la dernière piste sélectionnée. Sinon, piste par piste pour que
  -- chaque duplicata suive sa source.
  local dups = {}
  if consecutive and #sources > 1 then
    reaper.Main_OnCommand(DUPLICATE_TRACKS, 0)
    for i = 0, reaper.CountSelectedTracks(0) - 1 do
      dups[#dups + 1] = reaper.GetSelectedTrack(0, i)
    end
  else
    for _, src in ipairs(sources) do
      reaper.SetOnlyTrackSelected(src)
      reaper.Main_OnCommand(DUPLICATE_TRACKS, 0)
      dups[#dups + 1] = reaper.GetSelectedTrack(0, 0)
    end
  end

  for i, dup in ipairs(dups) do
    -- Les duplicata ne gardent aucun item
    for j = reaper.CountTrackMediaItems(dup) - 1, 0, -1 do
      reaper.DeleteTrackMediaItem(dup, reaper.GetTrackMediaItem(dup, j))
    end

    if not keep_env then
      local ok, chunk = reaper.GetTrackStateChunk(dup, "", false)
      if ok then
        reaper.SetTrackStateChunk(dup, stripEnvelopes(chunk), false)
      end
    end

    incrementTrailingNumber(dup)

    if move_items then
      for _, item in ipairs(items_by_source[i]) do
        reaper.MoveMediaItemToTrack(item, dup)
      end
    end
  end

  -- Laisser les duplicata sélectionnés (comportement natif de la duplication)
  reaper.SetOnlyTrackSelected(dups[1])
  for i = 2, #dups do
    reaper.SetTrackSelected(dups[i], true)
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.TrackList_AdjustWindows(false)
  reaper.Undo_EndBlock("Duplicate selected tracks", -1)
end

main()
