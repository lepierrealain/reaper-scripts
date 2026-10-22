-- @description Duplicate selected region with offset, preserving beat within measure
-- @author lepierrealain
-- @version 1.1
-- @requires ReaImGui
-- @about
--   Duplique une région et son contenu sur les mêmes pistes (REAPER 6.59+).
--   Région sélectionnée dans la règle / le gestionnaire ; sinon, sélection
--   temporelle correspondant exactement à une région ; sinon, région au curseur.
--   Demande un décalage positif ou nul en secondes ou mesures, après la fin
--   de la région. Les décimales sont acceptées (point ou virgule).
--   Fenêtre ReaImGui avec boutons radio Secondes / Mesures.
--   Arrondit vers le haut au même temps et à la même fraction de temps que le
--   début source. La copie est placée au plus tôt après la fin de l'original.
--   Comme une copie native de région, insère de l'espace et décale la suite du
--   projet, en copiant aussi les automations et les changements de tempo.
--   Conserve le nom, la couleur et la lane de la région. Une seule annulation.

local r = reaper
local PROJECT = r.EnumProjects(-1)
local TITLE = "Dupliquer la région avec décalage"
local EXT_SECTION = "PA_DuplicateRegionWithOffset"
local COPY_TIME_SELECTION = 40397
local EPSILON = 1e-7

local function message(text)
  r.ShowMessageBox(text, TITLE, 0)
end

local function read_regions()
  local regions, selected = {}, {}
  for i = 0, r.CountProjectMarkers(PROJECT) - 1 do
    local ok, is_region, start_pos, end_pos, name, id, color =
      r.EnumProjectMarkers3(PROJECT, i)
    if ok ~= 0 and is_region then
      local region = { start_pos = start_pos, end_pos = end_pos,
        name = name, id = id, color = color }
      if r.GetRegionOrMarker and r.GetRegionOrMarkerInfo_Value then
        local marker = r.GetRegionOrMarker(PROJECT, i, "")
        if marker then
          region.lane = r.GetRegionOrMarkerInfo_Value(PROJECT, marker, "I_LANENUMBER")
          if r.GetRegionOrMarkerInfo_Value(PROJECT, marker, "B_UISEL") ~= 0 then
            selected[#selected + 1] = region
          end
        end
      end
      regions[#regions + 1] = region
    end
  end
  return regions, selected
end

local function choose_region(regions, selected)
  if #selected == 1 then return selected[1] end
  if #selected > 1 then
    return nil, "Sélectionnez une seule région à dupliquer."
  end

  local start_pos, end_pos = r.GetSet_LoopTimeRange2(PROJECT, false, false, 0, 0, false)
  if end_pos > start_pos then
    local match
    for _, region in ipairs(regions) do
      if math.abs(region.start_pos - start_pos) < EPSILON
          and math.abs(region.end_pos - end_pos) < EPSILON then
        if match then return nil, "Plusieurs régions ont ces limites. Sélectionnez-en une dans la règle." end
        match = region
      end
    end
    if match then return match end
    return nil, "La sélection temporelle doit correspondre à une région entière.\nDouble-cliquez sur la région, puis relancez le script."
  end

  local cursor, target = r.GetCursorPositionEx(PROJECT), nil
  for _, region in ipairs(regions) do
    if cursor >= region.start_pos and cursor < region.end_pos
        and (not target or region.start_pos > target.start_pos
          or (region.start_pos == target.start_pos and region.end_pos < target.end_pos)) then
      target = region
    end
  end
  return target, "Sélectionnez une région, ou placez le curseur à l'intérieur."
end

local function trim(text)
  return text:match("^%s*(.-)%s*$")
end

local function parse_amount(text)
  local amount = tonumber((trim(text):gsub(",", ".")))
  if amount and amount == amount and amount >= 0 and amount < math.huge then
    return amount
  end
end

-- Ajoute des mesures musicales, même si tempo et signature changent.
local function add_measures(position, amount)
  local beat, measure, length = r.TimeMap2_timeToBeats(PROJECT, position)
  local musical_pos = measure + beat / length + amount
  local target_measure = math.floor(musical_pos)
  local measure_start = r.TimeMap2_beatsToTime(PROJECT, 0, target_measure)
  local _, _, target_length = r.TimeMap2_timeToBeats(PROJECT, measure_start)
  return r.TimeMap2_beatsToTime(PROJECT,
    (musical_pos - target_measure) * target_length, target_measure)
end

local function destination(region, amount, unit)
  local reference = region.end_pos
  local requested = unit == "secondes" and reference + amount or add_measures(reference, amount)
  -- Ne pas insérer au milieu de la source : cela couperait son contenu.
  local minimum = math.max(requested, region.end_pos)
  local source_beat = r.TimeMap2_timeToBeats(PROJECT, region.start_pos)
  local _, measure = r.TimeMap2_timeToBeats(PROJECT, minimum)

  for _ = 1, 10000 do
    local measure_start = r.TimeMap2_beatsToTime(PROJECT, 0, measure)
    local measure_end = r.TimeMap2_beatsToTime(PROJECT, 0, measure + 1)
    local candidate = r.TimeMap2_beatsToTime(PROJECT, source_beat, measure)
    -- Une mesure plus courte peut ne pas contenir le temps de la source.
    if candidate < measure_end - EPSILON and candidate >= minimum - EPSILON
        and candidate >= measure_start - EPSILON then
      return candidate
    end
    measure = measure + 1
  end
  error("Aucune mesure compatible trouvée : vérifiez la signature rythmique à destination.", 0)
end

local function ensure_copied_region(source, dest, previous_ids)
  local dest_end = dest + source.end_pos - source.start_pos
  local regions = read_regions()
  local copy_id
  for _, region in ipairs(regions) do
    if not previous_ids[region.id] and region.name == source.name
        and math.abs(region.start_pos - dest) < EPSILON
        and math.abs(region.end_pos - dest_end) < EPSILON then
      copy_id = region.id
      break
    end
  end
  -- L'action native peut déjà avoir copié la région : éviter le doublon.
  if not copy_id then
    copy_id = r.AddProjectMarker2(PROJECT, true, dest, dest_end, source.name, -1, source.color)
    if copy_id < 0 then error("Impossible de créer la région dupliquée.", 0) end
  end
  if source.lane and r.SetRegionOrMarkerInfo_Value then
    for i = 0, r.GetNumRegionsOrMarkers(PROJECT) - 1 do
      local marker = r.GetRegionOrMarker(PROJECT, i, "")
      if r.GetRegionOrMarkerInfo_Value(PROJECT, marker, "B_ISREGION") ~= 0
          and r.GetRegionOrMarkerInfo_Value(PROJECT, marker, "I_NUMBER") == copy_id then
        r.SetRegionOrMarkerInfo_Value(PROJECT, marker, "I_LANENUMBER", source.lane)
        break
      end
    end
  end
end

local function duplicate_region(region, amount, unit)
  -- La fenêtre est non modale : vérifier la source avant toute modification.
  if r.EnumProjects(-1) ~= PROJECT then
    return false, "Revenez au projet d'origine pour dupliquer cette région."
  end
  local regions, current = read_regions(), nil
  for _, entry in ipairs(regions) do
    if entry.id == region.id and math.abs(entry.start_pos - region.start_pos) < EPSILON
        and math.abs(entry.end_pos - region.end_pos) < EPSILON then
      current = entry
      break
    end
  end
  if not current then
    return false, "La région source a été déplacée ou supprimée. Relancez le script."
  end
  region = current
  local ok, dest = pcall(destination, region, amount, unit)
  if not ok then return false, dest end

  local previous_ids = {}
  for _, entry in ipairs(regions) do previous_ids[entry.id] = true end
  local sel_start, sel_end = r.GetSet_LoopTimeRange2(PROJECT, false, false, 0, 0, false)
  local loop_start, loop_end = r.GetSet_LoopTimeRange2(PROJECT, false, true, 0, 0, false)
  local cursor = r.GetCursorPositionEx(PROJECT)
  local linked = r.GetToggleCommandStateEx(0, 40621) == 1

  r.Undo_BeginBlock2(PROJECT)
  r.PreventUIRefresh(1)
  local success, err = xpcall(function()
    if linked then r.Main_OnCommandEx(40621, 0, PROJECT) end
    r.GetSet_LoopTimeRange2(PROJECT, true, false, region.start_pos, region.end_pos, false)
    r.SetEditCurPos2(PROJECT, dest, false, false)
    r.Main_OnCommandEx(COPY_TIME_SELECTION, 0, PROJECT)
    ensure_copied_region(region, dest, previous_ids)
  end, debug.traceback)

  r.GetSet_LoopTimeRange2(PROJECT, true, false, sel_start, sel_end, false)
  r.GetSet_LoopTimeRange2(PROJECT, true, true, loop_start, loop_end, false)
  r.SetEditCurPos2(PROJECT, cursor, false, false)
  if linked and r.GetToggleCommandStateEx(0, 40621) ~= 1 then
    r.Main_OnCommandEx(40621, 0, PROJECT)
  end
  r.PreventUIRefresh(-1)
  r.UpdateTimeline()
  r.UpdateArrange()
  r.Undo_EndBlock2(PROJECT, "Dupliquer la région avec décalage", -1)
  if success then
    r.SetExtState(EXT_SECTION, "inputs", tostring(amount) .. ";" .. unit, true)
  else
    message("La duplication a échoué. Annulez l'opération avec Ctrl+Z si nécessaire.\n\n" .. err)
  end
  return true
end

local function show_offset_window(region)
  local script_dir = ({ r.get_action_context() })[2]:match("^(.+[\\/])")
  dofile(script_dir .. "../Libraries/PA_lib_gui.lua")
  local ctx = PA_GuiInit(TITLE)
  local amount_text, unit = r.GetExtState(EXT_SECTION, "inputs"):match("^([^;]*);([^;]*)$")
  if not amount_text or not parse_amount(amount_text) then amount_text = "1" end
  if unit ~= "secondes" then unit = "mesures" end
  local first_frame, error_text = true, nil

  local function loop()
    PA_GuiBeginFrame()
    if first_frame then PA_GuiWindowAtMouse(470, 320) end
    local visible, open = r.ImGui_Begin(ctx, TITLE, true,
      r.ImGui_WindowFlags_NoCollapse() | r.ImGui_WindowFlags_NoResize()
        | r.ImGui_WindowFlags_AlwaysAutoResize())
    local submit, cancel = false, false
    if visible then
      r.ImGui_TextWrapped(ctx, "Région : " .. (region.name ~= "" and region.name or tostring(region.id)))
      r.ImGui_Text(ctx, "Décalage après la fin de la région")
      r.ImGui_Spacing(ctx)
      if PA_GuiRadioButton("Secondes", unit == "secondes") then unit = "secondes" end
      r.ImGui_SameLine(ctx)
      if PA_GuiRadioButton("Mesures", unit == "mesures") then unit = "mesures" end
      r.ImGui_SetNextItemWidth(ctx, PA_S(180))
      if first_frame then r.ImGui_SetKeyboardFocusHere(ctx) end
      local changed
      changed, amount_text = r.ImGui_InputText(ctx, "Décalage", amount_text)
      if changed then error_text = nil end
      local amount = parse_amount(amount_text)
      if not amount then PA_GuiErrorText("Saisissez un nombre positif ou nul.") end
      r.ImGui_Spacing(ctx)
      r.ImGui_TextWrapped(ctx, "Arrondi vers le haut en conservant le temps de départ dans la mesure.")
      r.ImGui_TextWrapped(ctx, "La copie insère de l'espace et décale la suite du projet.")
      if error_text then PA_GuiErrorText(error_text) end
      r.ImGui_Spacing(ctx)
      r.ImGui_BeginDisabled(ctx, amount == nil)
      submit = r.ImGui_Button(ctx, "Dupliquer", PA_S(150), 0)
        or (amount ~= nil and r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Enter()))
      r.ImGui_EndDisabled(ctx)
      r.ImGui_SameLine(ctx)
      cancel = r.ImGui_Button(ctx, "Annuler", PA_S(120), 0)
        or r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape())
      r.ImGui_End(ctx)
    end
    PA_GuiEndFrame()
    first_frame = false

    if not open or cancel then return end
    if submit then
      local done, reason = duplicate_region(region, parse_amount(amount_text), unit)
      if done then return end
      error_text = reason
    end
    r.defer(loop)
  end
  r.defer(loop)
end

local function main()
  -- Évite un point d'annulation automatique si la fenêtre est annulée.
  r.defer(function() end)
  local major, minor = r.GetAppVersion():match("^(%d+)%.(%d+)")
  if not major or tonumber(major) < 6 or (tonumber(major) == 6 and tonumber(minor) < 59) then
    message("Ce script nécessite REAPER 6.59 ou supérieur.")
    return
  end
  if not r.ImGui_CreateContext then
    message("Cette fenêtre nécessite l'extension ReaImGui.\nInstallez-la via ReaPack.")
    return
  end
  local regions, selected = read_regions()
  local region, reason = choose_region(regions, selected)
  if not region then message(reason) return end
  show_offset_window(region)
end

main()
