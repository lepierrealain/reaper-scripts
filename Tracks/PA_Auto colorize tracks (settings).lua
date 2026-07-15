-- @description Auto colorize tracks: settings window
-- @author lepierrealain
-- @version 1.3
-- @requires ReaImGui
-- @about
--   Settings window for the automatic track colorizer:
--   palette (add, remove, edit, drag-and-drop reordering), loop or stable
--   random assignment, user color preservation, child track shading
--   (saturation/lightness, inheritance level, cumulative shading, same
--   color for consecutive childless tracks). Changes apply live (option)
--   and wake the "PA_Auto colorize tracks" watcher if it is running.

local lib_path = ({ reaper.get_action_context() })[2]:match("^(.+[\\/])")
local lib_root = lib_path .. ".." .. package.config:sub(1, 1) .. "Libraries" .. package.config:sub(1, 1)
dofile(lib_root .. "PA_lib_color.lua")
dofile(lib_root .. "PA_lib_gui.lua")

if not reaper.ImGui_CreateContext then
  reaper.ShowMessageBox("This window requires the ReaImGui extension (ReaPack).",
    "Auto colorize — settings", 0)
  return
end

local ctx = PA_GuiInit("PA_AutoColorizeSettings")
local S = PA_S

local WIN_W, WIN_H = 420, 785

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

local section = PA_GuiSection

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
  local list_h = math.max(S(90), avail_h - S(651))
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

  if reaper.ImGui_Button(ctx, "+ Add") then
    s.palette[#s.palette + 1] = s.palette[#s.palette] or 0x5B8CFF
    changed = true
  end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, "Default palette") then
    reaper.ImGui_OpenPopup(ctx, "Default palette?")
  end

  -- Confirmation : le reset écrase la palette personnalisée
  local vp = reaper.ImGui_GetMainViewport(ctx)
  local vx, vy = reaper.ImGui_Viewport_GetWorkPos(vp)
  local sw, sh = reaper.ImGui_Viewport_GetWorkSize(vp)
  reaper.ImGui_SetNextWindowPos(ctx, vx + sw * 0.5, vy + sh * 0.5,
    reaper.ImGui_Cond_Appearing(), 0.5, 0.5)
  if reaper.ImGui_BeginPopupModal(ctx, "Default palette?", nil,
    reaper.ImGui_WindowFlags_AlwaysAutoResize()) then
    reaper.ImGui_Text(ctx, "Replace the current palette with the default one?")
    reaper.ImGui_TextDisabled(ctx, "Custom colors will be lost.")
    reaper.ImGui_Spacing(ctx)
    if reaper.ImGui_Button(ctx, "Replace") then
      s.palette = PA_ColorDefaultPalette()
      pal_uids = {}
      changed = true
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Cancel") then
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
  reaper.ImGui_TextDisabled(ctx, "Click: edit — handle on the right: reorder")
  changed = drawPalette() or changed

  section("Assignment")
  if PA_GuiRadioButton("Loop", s.mode == "loop") and s.mode ~= "loop" then
    s.mode = "loop"; changed = true
  end
  reaper.ImGui_SameLine(ctx)
  if PA_GuiRadioButton("Random", s.mode == "random") and s.mode ~= "random" then
    s.mode = "random"; changed = true
  end
  if s.mode == "random" then
    reaper.ImGui_SameLine(ctx)
    -- même hauteur que les radios de la ligne
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), S(12), S(5))
    if reaper.ImGui_Button(ctx, "Reroll") then
      s.seed = s.seed + 1  -- l'aléatoire est stable par piste : seul le seed re-tire
      changed = true
    end
    reaper.ImGui_PopStyleVar(ctx)
  end

  local rv
  rv, s.preserve = PA_GuiCheckbox("Preserve user colors", s.preserve)
  changed = rv or changed
  reaper.ImGui_TextDisabled(ctx, "Only colors tracks that use the default color,")
  reaper.ImGui_TextDisabled(ctx, "or already colored by the script and untouched since.")

  rv, s.childless_same = PA_GuiCheckbox(
    "Same color for consecutive childless tracks", s.childless_same)
  changed = rv or changed
  reaper.ImGui_TextDisabled(ctx, "Consecutive tracks with no children share their color;")
  reaper.ImGui_TextDisabled(ctx, "a folder always starts a new color.")

  section("Child tracks")
  local v
  reaper.ImGui_SetNextItemWidth(ctx, S(180))
  rv, v = reaper.ImGui_SliderInt(ctx, "Inherit from level", math.floor(s.child_depth), 1, 8)
  if rv then s.child_depth = v; changed = true end
  reaper.ImGui_TextDisabled(ctx, "1: direct children already inherit from their parent.")
  reaper.ImGui_TextDisabled(ctx, "Above, only folders take their own color.")

  reaper.ImGui_SetNextItemWidth(ctx, S(180))
  rv, v = reaper.ImGui_SliderInt(ctx, "Children saturation",
    math.floor(s.child_sat * 100 + 0.5), 20, 200, "%d %%")
  if rv then s.child_sat = v / 100; changed = true end

  reaper.ImGui_SetNextItemWidth(ctx, S(180))
  rv, v = reaper.ImGui_SliderInt(ctx, "Children lightness",
    math.floor(s.child_lum * 100 + 0.5), 20, 200, "%d %%")
  if rv then s.child_lum = v / 100; changed = true end

  rv, s.cumulative = PA_GuiCheckbox("Cumulative shading per level", s.cumulative)
  changed = rv or changed

  -- Aperçu : parent puis trois niveaux d'enfants avec les réglages courants
  if s.palette[1] then
    reaper.ImGui_Text(ctx, "Preview")
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

  section("Apply")
  rv, s.live = PA_GuiCheckbox("Apply live", s.live)
  changed = rv or changed

  if reaper.ImGui_Button(ctx, "Apply") then
    PA_ColorSaveSettings(s)
    PA_ColorizeApply(s, false)
  end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, "Recolor all") then
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

  local visible, open = reaper.ImGui_Begin(ctx, "Auto colorize — settings", true,
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
