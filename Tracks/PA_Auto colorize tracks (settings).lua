-- @description Auto colorize tracks: settings window
-- @author lepierrealain
-- @version 1.0
-- @requires ReaImGui
-- @about
--   Fenêtre de réglages du colorisateur automatique de pistes :
--   palette (ajout, suppression, édition, réordonnancement par glisser-déposer),
--   attribution en boucle ou aléatoire stable, préservation des couleurs
--   utilisateur, déclinaison des enfants (saturation/luminosité, niveau
--   d'héritage, dégradé cumulatif). Les changements s'appliquent en direct
--   (option) et réveillent le watcher "PA_Auto colorize tracks" s'il tourne.

local lib_path = ({ reaper.get_action_context() })[2]:match("^(.+[\\/])")
local lib_root = lib_path .. ".." .. package.config:sub(1, 1) .. "Libraries" .. package.config:sub(1, 1)
dofile(lib_root .. "PA_lib_color.lua")
dofile(lib_root .. "PA_lib_gui.lua")

if not reaper.ImGui_CreateContext then
  reaper.ShowMessageBox("Cette fenêtre nécessite l'extension ReaImGui (ReaPack).",
    "Auto colorize — réglages", 0)
  return
end

local ctx = PA_GuiInit("PA_AutoColorizeSettings")
local S = PA_S

local WIN_W, WIN_H = 420, 760

local s = PA_ColorLoadSettings()
local win_init = true
local scale_dirty = false  -- redimensionne la fenêtre à la frame suivant un changement d'échelle

-- Taille de fenêtre choisie par l'utilisateur, mémorisée hors échelle
-- (un changement d'échelle conserve les proportions).
local EXT = "PA_AutoColorize"

local function loadWinSize()
  local w = tonumber(reaper.GetExtState(EXT, "win_w"))
  local h = tonumber(reaper.GetExtState(EXT, "win_h"))
  if w and h and w >= 300 and h >= 360 then return w, h end
  return WIN_W, WIN_H
end

local saved_w, saved_h = loadWinSize()

local function rememberWinSize()
  local w, h = reaper.ImGui_GetWindowSize(ctx)
  -- PA_S(1) = échelle effective (échelle UI × mode compact)
  local uw, uh = w / PA_S(1), h / PA_S(1)
  if math.abs(uw - saved_w) > 2 or math.abs(uh - saved_h) > 2 then
    saved_w, saved_h = uw, uh
    reaper.SetExtState(EXT, "win_w", string.format("%.0f", uw), true)
    reaper.SetExtState(EXT, "win_h", string.format("%.0f", uh), true)
  end
end

-- SeparatorText n'existe que dans les ReaImGui récents
local function section(label)
  if reaper.ImGui_SeparatorText then
    reaper.ImGui_SeparatorText(ctx, label)
  else
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Text(ctx, label)
    reaper.ImGui_Separator(ctx)
  end
end

local function rgba(rgb) return (rgb << 8) | 0xFF end

-- ─── Palette : liste éditable, poignée pour réordonner ──────────────────

-- Identifiants stables par entrée de palette (les couleurs peuvent être en
-- double) : la poignée garde son ID pendant le glissement même quand la
-- ligne change de position, comme les favoris d'Add plugin.
local next_uid = 0
local pal_uids = {}

local function syncUids()
  for i = 1, #s.palette do
    if not pal_uids[i] then
      next_uid = next_uid + 1
      pal_uids[i] = next_uid
    end
  end
  for i = #pal_uids, #s.palette + 1, -1 do
    table.remove(pal_uids, i)
  end
end

local function drawPalette()
  local changed = false
  local delete_idx
  syncUids()

  -- La liste s'étire avec la fenêtre : tout l'espace restant moins la place
  -- (approximative, hors échelle) qu'occupent les sections en dessous.
  local _, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
  local list_h = math.max(S(90), avail_h - S(626))
  if reaper.ImGui_BeginChild(ctx, "##palette", 0, list_h) then
    local swatch_flags = reaper.ImGui_ColorEditFlags_NoInputs()
                       | reaper.ImGui_ColorEditFlags_NoDragDrop()
    local win_w = reaper.ImGui_GetWindowWidth(ctx)
    local dl = reaper.ImGui_GetWindowDrawList(ctx)

    for i, col in ipairs(s.palette) do
      reaper.ImGui_PushID(ctx, pal_uids[i])

      local rv, nc = reaper.ImGui_ColorEdit3(ctx, "##col", col, swatch_flags)
      if rv then
        s.palette[i] = nc & 0xFFFFFF
        changed = true
      end
      local _, ry0 = reaper.ImGui_GetItemRectMin(ctx)
      local _, ry1 = reaper.ImGui_GetItemRectMax(ctx)

      reaper.ImGui_SameLine(ctx)
      reaper.ImGui_Text(ctx, string.format("%d.  #%06X", i, s.palette[i]))

      -- Poignée de réordonnancement : tant qu'elle est tenue, la couleur
      -- échange sa place avec sa voisine dès que la souris sort de la ligne.
      reaper.ImGui_SameLine(ctx)
      reaper.ImGui_SetCursorPosX(ctx, win_w - S(76))
      reaper.ImGui_InvisibleButton(ctx, "##grip", S(22), reaper.ImGui_GetFrameHeight(ctx))
      local gx0, gy0 = reaper.ImGui_GetItemRectMin(ctx)
      local gx1, gy1 = reaper.ImGui_GetItemRectMax(ctx)
      local g_hov = reaper.ImGui_IsItemHovered(ctx)
      local g_act = reaper.ImGui_IsItemActive(ctx)
      local g_col = g_act and 0xFFFFFF99 or (g_hov and 0xFFFFFF55 or 0xFFFFFF26)
      local gcx, gcy = (gx0 + gx1) * 0.5, (gy0 + gy1) * 0.5
      for off = -1, 1 do
        local ly = gcy + off * S(4)
        reaper.ImGui_DrawList_AddLine(dl, gcx - S(5), ly, gcx + S(5), ly, g_col, S(1.4))
      end
      if g_hov or g_act then
        reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeNS())
      end
      if g_act then
        local _, my = reaper.ImGui_GetMousePos(ctx)
        local j
        if my < ry0 and i > 1 then
          j = i - 1
        elseif my > ry1 and i < #s.palette then
          j = i + 1
        end
        if j then
          s.palette[i], s.palette[j] = s.palette[j], s.palette[i]
          pal_uids[i], pal_uids[j] = pal_uids[j], pal_uids[i]
          changed = true
        end
      end

      if #s.palette > 1 then
        reaper.ImGui_SameLine(ctx, win_w - S(44))
        if reaper.ImGui_SmallButton(ctx, "X") then delete_idx = i end
      end

      reaper.ImGui_PopID(ctx)
    end
    reaper.ImGui_EndChild(ctx)
  end

  if delete_idx then
    table.remove(s.palette, delete_idx)
    table.remove(pal_uids, delete_idx)
    changed = true
  end

  if reaper.ImGui_Button(ctx, "+ Ajouter") then
    s.palette[#s.palette + 1] = s.palette[#s.palette] or 0x5B8CFF
    changed = true
  end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, "Palette par défaut") then
    reaper.ImGui_OpenPopup(ctx, "Palette par défaut ?")
  end

  -- Confirmation : le reset écrase la palette personnalisée
  local vp = reaper.ImGui_GetMainViewport(ctx)
  local vx, vy = reaper.ImGui_Viewport_GetWorkPos(vp)
  local sw, sh = reaper.ImGui_Viewport_GetWorkSize(vp)
  reaper.ImGui_SetNextWindowPos(ctx, vx + sw * 0.5, vy + sh * 0.5,
    reaper.ImGui_Cond_Appearing(), 0.5, 0.5)
  if reaper.ImGui_BeginPopupModal(ctx, "Palette par défaut ?", nil,
    reaper.ImGui_WindowFlags_AlwaysAutoResize()) then
    reaper.ImGui_Text(ctx, "Remplacer la palette actuelle par la palette par défaut ?")
    reaper.ImGui_TextDisabled(ctx, "Les couleurs personnalisées seront perdues.")
    reaper.ImGui_Spacing(ctx)
    if reaper.ImGui_Button(ctx, "Remplacer") then
      s.palette = PA_ColorDefaultPalette()
      pal_uids = {}
      changed = true
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Annuler") then
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndPopup(ctx)
  end

  return changed
end

-- ─── Corps de la fenêtre ────────────────────────────────────────────────

local function drawUI()
  local changed = false

  section("Palette")
  reaper.ImGui_TextDisabled(ctx, "Clic : éditer — poignée à droite : réordonner")
  changed = drawPalette() or changed

  section("Attribution")
  if reaper.ImGui_RadioButton(ctx, "Boucle", s.mode == "loop") and s.mode ~= "loop" then
    s.mode = "loop"; changed = true
  end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_RadioButton(ctx, "Aléatoire", s.mode == "random") and s.mode ~= "random" then
    s.mode = "random"; changed = true
  end
  if s.mode == "random" then
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Re-tirer") then
      s.seed = s.seed + 1  -- l'aléatoire est stable par piste : seul le seed re-tire
      changed = true
    end
  end

  local rv
  rv, s.preserve = reaper.ImGui_Checkbox(ctx, "Préserver les couleurs de l'utilisateur", s.preserve)
  changed = rv or changed
  reaper.ImGui_TextDisabled(ctx, "Ne colorise que les pistes en couleur par défaut,")
  reaper.ImGui_TextDisabled(ctx, "ou déjà colorisées par le script et pas retouchées.")

  section("Pistes enfants")
  local v
  reaper.ImGui_SetNextItemWidth(ctx, S(180))
  rv, v = reaper.ImGui_SliderInt(ctx, "Héritage dès le niveau", math.floor(s.child_depth), 1, 8)
  if rv then s.child_depth = v; changed = true end
  reaper.ImGui_TextDisabled(ctx, "1 : les enfants directs héritent déjà du parent.")
  reaper.ImGui_TextDisabled(ctx, "Au-dessus, seuls les dossiers prennent leur propre couleur.")

  reaper.ImGui_SetNextItemWidth(ctx, S(180))
  rv, v = reaper.ImGui_SliderInt(ctx, "Saturation enfants",
    math.floor(s.child_sat * 100 + 0.5), 20, 200, "%d %%")
  if rv then s.child_sat = v / 100; changed = true end

  reaper.ImGui_SetNextItemWidth(ctx, S(180))
  rv, v = reaper.ImGui_SliderInt(ctx, "Luminosité enfants",
    math.floor(s.child_lum * 100 + 0.5), 20, 200, "%d %%")
  if rv then s.child_lum = v / 100; changed = true end

  rv, s.cumulative = reaper.ImGui_Checkbox(ctx, "Dégradé cumulatif par niveau", s.cumulative)
  changed = rv or changed

  -- Aperçu : parent puis trois niveaux d'enfants avec les réglages courants
  if s.palette[1] then
    reaper.ImGui_Text(ctx, "Aperçu")
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_ColorButton(ctx, "##pv0", rgba(s.palette[1]),
      reaper.ImGui_ColorEditFlags_NoTooltip())
    for lvl = 1, 3 do
      reaper.ImGui_SameLine(ctx)
      local shade = PA_ColorChildShade(s.palette[1],
        s.cumulative and lvl or 1, s.child_sat, s.child_lum)
      reaper.ImGui_ColorButton(ctx, "##pv" .. lvl, rgba(shade),
        reaper.ImGui_ColorEditFlags_NoTooltip())
    end
  end

  section("Application")
  rv, s.live = reaper.ImGui_Checkbox(ctx, "Appliquer en direct", s.live)
  changed = rv or changed

  if reaper.ImGui_Button(ctx, "Appliquer") then
    PA_ColorSaveSettings(s)
    PA_ColorizeApply(s, false)
  end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, "Tout recoloriser") then
    PA_ColorSaveSettings(s)
    PA_ColorizeApply(s, true)  -- ignore "préserver" pour cette passe
  end
  reaper.ImGui_SameLine(ctx)
  if PA_GuiScaleCombo("##scale") then scale_dirty = true end

  if changed then
    PA_ColorSaveSettings(s)  -- réveille aussi le watcher via le stamp
    if s.live then PA_ColorizeApply(s, false) end
  end
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
  reaper.ImGui_SetNextWindowSizeConstraints(ctx, S(340), S(420), 16384, 16384)

  local visible, open = reaper.ImGui_Begin(ctx, "Auto colorize — réglages", true,
    reaper.ImGui_WindowFlags_NoCollapse())
  if visible then
    rememberWinSize()
    drawUI()
    -- Échap ferme la fenêtre, sauf si une popup (modale, color picker) est
    -- ouverte : dans ce cas ImGui la ferme lui-même.
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
