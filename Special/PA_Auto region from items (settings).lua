-- @description Automatically add region from items from tracks: settings window
-- @author lepierrealain
-- @version 1.2
-- @requires ReaImGui
-- @about
--   Fenêtre de réglages de "PA_Auto region from items" : prefix global, mode
--   de nommage (single / item name / numbering / item group), séparateur,
--   sélection des pistes suivies et nom de région par piste. En mode item
--   group, un nom de base dédié est incrémenté par groupe REAPER (I_GROUPID)
--   dans l'ordre chronologique. "Apply" sauvegarde dans le
--   projet, applique une passe immédiate et réveille le watcher s'il tourne
--   (sans watcher, ça équivaut à une application unique).

local lib_path = ({ reaper.get_action_context() })[2]:match("^(.+[\\/])")
local lib_root = lib_path .. ".." .. package.config:sub(1, 1) .. "Libraries" .. package.config:sub(1, 1)
dofile(lib_root .. "PA_lib_autoregion.lua")
dofile(lib_root .. "PA_lib_gui.lua")

if not reaper.BR_GetMediaItemGUID then
  reaper.ShowMessageBox(
    "Ce script nécessite l'extension SWS.\nTéléchargeable sur https://www.sws-extension.org/",
    "AutoRegionFromItems", 0)
  return
end

if not reaper.ImGui_CreateContext then
  reaper.ShowMessageBox(
    "Cette fenêtre nécessite l'extension ReaImGui.\nInstallez-la via ReaPack.",
    "AutoRegionFromItems", 0)
  return
end

local ctx = PA_GuiInit("PA_AutoRegionSettings")
local S = PA_S

local WIN_W, WIN_H = 620, 640

local win_init    = true
local scale_dirty = false  -- redimensionne la fenêtre à la frame suivant un changement d'échelle

-- Taille de fenêtre choisie par l'utilisateur, mémorisée hors échelle
-- (un changement d'échelle conserve les proportions).
local EXT_GUI = "PA_AutoRegion"

local function loadWinSize()
  local w = tonumber(reaper.GetExtState(EXT_GUI, "win_w"))
  local h = tonumber(reaper.GetExtState(EXT_GUI, "win_h"))
  if w and h and w >= 480 and h >= 360 then return w, h end
  return WIN_W, WIN_H
end

local saved_w, saved_h = loadWinSize()

local function rememberWinSize()
  local w, h = reaper.ImGui_GetWindowSize(ctx)
  -- PA_S(1) = échelle effective (échelle UI × mode compact)
  local uw, uh = w / PA_S(1), h / PA_S(1)
  if math.abs(uw - saved_w) > 2 or math.abs(uh - saved_h) > 2 then
    saved_w, saved_h = uw, uh
    reaper.SetExtState(EXT_GUI, "win_w", string.format("%.0f", uw), true)
    reaper.SetExtState(EXT_GUI, "win_h", string.format("%.0f", uh), true)
  end
end

-- Ordre d'affichage du combo (Single en premier) ; les valeurs de mode
-- persistées restent inchangées grâce à la table de correspondance.
local MODE_LABELS   = { "Single mode", "Item name", "Numbering", "Item group" }
local COMBO_TO_MODE = { [0] = PA_AR_MODE_SINGLE, [1] = PA_AR_MODE_ITEM, [2] = PA_AR_MODE_NUM, [3] = PA_AR_MODE_GROUP }
local MODE_TO_COMBO = { [PA_AR_MODE_SINGLE] = 0, [PA_AR_MODE_ITEM] = 1, [PA_AR_MODE_NUM] = 2, [PA_AR_MODE_GROUP] = 3 }

-- ─── État UI ────────────────────────────────────────────────────────────

local state = PA_AR_LoadState()

local ui_title       = state.title or ""
local ui_mode        = state.mode or PA_AR_MODE_SINGLE
local ui_padding_str = tostring(state.padding or 1)
local ui_sep         = state.sep or "_"
local ui_group       = state.group or ""
local ui_checks      = {}   -- tguid → bool
local ui_names       = {}   -- tguid → nom de région éditable (défaut : nom de la piste)
local ui_tracks      = {}   -- liste ordonnée { guid, name, depth, color }

-- Valeur de mode inattendue (ExtState corrompu) → retour au défaut,
-- sinon MODE_TO_COMBO[ui_mode] serait nil et le combo planterait.
if MODE_TO_COMBO[ui_mode] == nil then ui_mode = PA_AR_MODE_SINGLE end

local function buildTrackList()
  ui_tracks = {}
  local n = reaper.CountTracks(0)
  local depth = 0
  for i = 0, n - 1 do
    local track  = reaper.GetTrack(0, i)
    local guid   = reaper.GetTrackGUID(track)
    local _, name = reaper.GetTrackName(track)
    local color  = reaper.GetTrackColor(track)
    ui_tracks[#ui_tracks + 1] = { guid = guid, name = name, depth = depth, color = color }
    local fd = reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH")
    if fd >= 1 then depth = depth + 1
    elseif fd < 0 then depth = math.max(0, depth + fd) end
  end
end

buildTrackList()
do
  local watched_set = {}
  for _, g in ipairs(state.guids) do watched_set[g] = true end
  for _, t in ipairs(ui_tracks) do
    ui_checks[t.guid] = watched_set[t.guid] or false
    local cfg = state.cfg[t.guid]
    if cfg and cfg.name then
      ui_names[t.guid] = cfg.name
    elseif ui_checks[t.guid] then
      ui_names[t.guid] = t.name
    end
  end
end

-- Reporte l'état UI courant dans `state` (sans sauvegarder)
local function collectIntoState()
  local selected = {}
  local new_cfg  = {}
  local padding  = tonumber(ui_padding_str) or 1
  if padding < 1 then padding = 1 end
  for _, t in ipairs(ui_tracks) do
    if ui_checks[t.guid] then
      selected[#selected + 1] = t.guid
      local cfg = {}
      -- On ne persiste le nom que s'il diffère du nom de la piste :
      -- ainsi un nom non modifié continue de suivre les renommages de piste.
      local nm = ui_names[t.guid]
      if nm ~= nil and nm ~= t.name then cfg.name = nm end
      new_cfg[t.guid] = cfg
    end
  end
  state.guids   = selected
  state.cfg     = new_cfg
  state.title   = ui_title
  state.mode    = ui_mode
  state.padding = padding
  state.sep     = (ui_sep and ui_sep ~= "") and ui_sep or "_"
  state.group   = ui_group
end

-- ─── Corps de la fenêtre ────────────────────────────────────────────────

-- Retourne true si l'utilisateur veut fermer la fenêtre
local function drawUI()
  PA_GuiSection("Naming")

  -- Libellés en colonne, champs alignés à S(120)
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, "Prefix")
  reaper.ImGui_SameLine(ctx, S(120))
  reaper.ImGui_SetNextItemWidth(ctx, S(200))
  local rt, tv = reaper.ImGui_InputText(ctx, "##title", ui_title)
  if rt then ui_title = tv end

  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, "Item naming")
  reaper.ImGui_SameLine(ctx, S(120))
  reaper.ImGui_SetNextItemWidth(ctx, S(200))
  local rm, nm = reaper.ImGui_Combo(ctx, "##mode", MODE_TO_COMBO[ui_mode],
    table.concat(MODE_LABELS, "\0") .. "\0")
  if rm then ui_mode = COMBO_TO_MODE[nm] end

  -- Padding (modes Numbering et Item group : les deux numérotent)
  if ui_mode == PA_AR_MODE_NUM or ui_mode == PA_AR_MODE_GROUP then
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_SetNextItemWidth(ctx, S(44))
    local rp, pv = reaper.ImGui_InputText(ctx, "##pad", ui_padding_str)
    if rp then ui_padding_str = pv end
  end

  -- Nom de base du mode Item group (composant qui s'incrémente par groupe)
  if ui_mode == PA_AR_MODE_GROUP then
    reaper.ImGui_AlignTextToFramePadding(ctx)
    reaper.ImGui_Text(ctx, "Group name")
    reaper.ImGui_SameLine(ctx, S(120))
    reaper.ImGui_SetNextItemWidth(ctx, S(200))
    local rg, gv = reaper.ImGui_InputText(ctx, "##group", ui_group)
    if rg then ui_group = gv end
  end

  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, "Separator")
  reaper.ImGui_SameLine(ctx, S(120))
  reaper.ImGui_SetNextItemWidth(ctx, S(44))
  local rs, sv = reaper.ImGui_InputText(ctx, "##sep", ui_sep)
  if rs then ui_sep = sv end

  PA_GuiSection("Tracks")
  reaper.ImGui_TextDisabled(ctx, "Check a track to watch it — region name editable on the right")

  -- La liste s'étire avec la fenêtre : tout l'espace restant moins la place
  -- (approximative, hors échelle) qu'occupent les sections en dessous.
  local _, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
  local list_h = math.max(S(110), avail_h - S(140))
  if reaper.ImGui_BeginChild(ctx, "##tracklist", 0, list_h) then
    -- Lignes compactes : checkboxes et champs de nom à la même hauteur réduite
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), S(12), S(5))

    for _, t in ipairs(ui_tracks) do
      if t.depth > 0 then reaper.ImGui_Indent(ctx, t.depth * S(12)) end

      -- Couleur de piste
      local has_color = t.color ~= 0
      if has_color then
        local r = (t.color >> 16) & 0xFF
        local g = (t.color >> 8)  & 0xFF
        local b =  t.color        & 0xFF
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), (r << 24) | (g << 16) | (b << 8) | 0xFF)
      end

      local rv, checked = reaper.ImGui_Checkbox(ctx, t.name .. "##chk_" .. t.guid, ui_checks[t.guid])
      if rv then
        ui_checks[t.guid] = checked
        if checked and ui_names[t.guid] == nil then ui_names[t.guid] = t.name end
      end

      if has_color then reaper.ImGui_PopStyleColor(ctx) end

      -- Nom de région éditable, aligné en colonne à droite des checkboxes.
      -- Vide → pas de composant "nom" dans le nommage (pas de séparateur).
      if ui_checks[t.guid] then
        reaper.ImGui_SameLine(ctx, S(300))
        reaper.ImGui_SetNextItemWidth(ctx, -S(8))
        local rn, nv = reaper.ImGui_InputText(ctx, "##name_" .. t.guid, ui_names[t.guid] or t.name)
        if rn then ui_names[t.guid] = nv end
      end

      if t.depth > 0 then reaper.ImGui_Unindent(ctx, t.depth * S(12)) end
    end

    reaper.ImGui_PopStyleVar(ctx)
    reaper.ImGui_EndChild(ctx)
  end

  if reaper.ImGui_Button(ctx, "Refresh tracks") then
    local saved_checks = {}
    for guid, v in pairs(ui_checks) do saved_checks[guid] = v end
    buildTrackList()
    for _, t in ipairs(ui_tracks) do
      ui_checks[t.guid] = saved_checks[t.guid] or false
    end
  end

  PA_GuiSection("Apply")

  if reaper.ImGui_Button(ctx, "Apply", S(110), 0) then
    -- Recharger les mappings depuis l'ExtState : si le watcher tourne, il a
    -- pu créer des régions depuis l'ouverture de la fenêtre — repartir de
    -- notre copie locale créerait des doublons.
    state = PA_AR_LoadState()
    collectIntoState()
    PA_AR_Resync(state)
    PA_AR_TouchStamp()  -- réveille le watcher pour qu'il recharge l'état
  end

  reaper.ImGui_SameLine(ctx)

  if reaper.ImGui_Button(ctx, "Close", S(90), 0) then
    return true
  end

  reaper.ImGui_SameLine(ctx)
  if PA_GuiScaleCombo("##scale") then scale_dirty = true end

  return false
end

-- ─── Boucle ─────────────────────────────────────────────────────────────

local function loop()
  PA_GuiBeginFrame()
  PA_GuiBeginCompact()  -- fenêtre de paramètres : tout ~20 % plus petit
  if win_init then
    PA_GuiWindowAtMouse(saved_w, saved_h)
    win_init = false
  elseif scale_dirty then
    PA_GuiResizeWindow(saved_w, saved_h)
    scale_dirty = false
  end
  reaper.ImGui_SetNextWindowSizeConstraints(ctx, S(480), S(400), 16384, 16384)

  local visible, open = reaper.ImGui_Begin(ctx, "Auto region from items — settings", true,
    reaper.ImGui_WindowFlags_NoCollapse())
  if visible then
    rememberWinSize()
    if drawUI() then open = false end
    -- Échap ferme la fenêtre, sauf si une popup (combo ouvert…) la gère déjà
    if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape())
      and not reaper.ImGui_IsPopupOpen(ctx, "", reaper.ImGui_PopupFlags_AnyPopup()) then
      open = false
    end
    reaper.ImGui_End(ctx)
  end

  PA_GuiEndCompact()
  PA_GuiEndFrame()
  if open then reaper.defer(loop) end
end

reaper.defer(loop)
