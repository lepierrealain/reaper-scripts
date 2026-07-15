-- @description Shared GUI helpers for PA_ scripts (ReaImGui theme, scale, widgets)
-- @author lepierrealain
-- @version 1.2
-- @requires ReaImGui

-- Thème, échelle d'interface et widgets communs aux scripts PA_.
-- L'échelle est persistée dans la section partagée PA_GUI de reaper-extstate.ini,
-- donc un seul réglage vaut pour tous les scripts.
--
-- Usage typique :
--   dofile(lib_root .. "PA_lib_gui.lua")
--   local ctx = PA_GuiInit("Mon script")
--   local function loop()
--     PA_GuiBeginFrame()
--     if win_init then PA_GuiWindowAtMouse(330, 200); win_init = false end
--     local visible = reaper.ImGui_Begin(ctx, ...)
--     ... widgets ...
--     reaper.ImGui_End(ctx)
--     PA_GuiEndFrame()
--     if open then reaper.defer(loop) end
--   end

local GUI_SECTION = "PA_GUI"

-- ─── Échelle d'interface ────────────────────────────────────────────────

local scale = tonumber(reaper.GetExtState(GUI_SECTION, "ui_scale"))
  or tonumber(reaper.GetExtState("PA_AddPlugin", "ui_scale"))  -- migration ancienne clé
  or 1.0
if scale < 0.5 or scale > 3 then scale = 1.0 end

-- Multiplicateur temporaire du mode compact (fenêtres secondaires réduites)
local compact = 1.0

-- Multiplie une dimension par l'échelle courante (× compact si actif).
function PA_S(v) return v * scale * compact end

function PA_GuiScale() return scale end

function PA_GuiSetScale(s)
  scale = s
  reaper.SetExtState(GUI_SECTION, "ui_scale", tostring(s), true)
end

-- ─── Palette partagée ───────────────────────────────────────────────────

PA_GuiCol = {
  ACCENT      = 0x5B8CFFFF,  -- sélection / éléments actifs
  ACCENT_BG   = 0x5B8CFF34,
  ACCENT_TEXT = 0xBFD2FFFF,
  HOVER_BG    = 0xFFFFFF0C,
  GOLD        = 0xE9C46AFF,  -- favoris / mise en avant
  GOLD_TEXT   = 0xF0DA9AFF,
  GOLD_BG     = 0xE9C46A12,
  PILL_BG     = 0xFFFFFF10,  -- pastilles neutres
  PILL_FG     = 0x9A9AA3FF,
  ERROR_TEXT  = 0xE07474FF,
  ICON        = 0xB8B8C2FF,
  ICON_HOVER  = 0xE8E8ECFF,
  ICON_DIM    = 0x8A8A93AA,
}

-- ─── État interne ───────────────────────────────────────────────────────

local ctx, font, font_badge
local THEME_COLORS, THEME_VARS

-- Construit les tables de thème (différé : reaper.ImGui_* ne doit être
-- touché qu'une fois ReaImGui garanti présent, pas au dofile)
local function buildTheme()
  THEME_COLORS = {
    { reaper.ImGui_Col_WindowBg(),             0x17171CFF },
    { reaper.ImGui_Col_PopupBg(),              0x1F1F26FF },
    { reaper.ImGui_Col_Border(),               0xFFFFFF1A },
    { reaper.ImGui_Col_Text(),                 0xE8E8ECFF },
    { reaper.ImGui_Col_TextDisabled(),         0x84848EFF },
    { reaper.ImGui_Col_FrameBg(),              0xFFFFFF12 },
    { reaper.ImGui_Col_FrameBgHovered(),       0xFFFFFF1A },
    { reaper.ImGui_Col_FrameBgActive(),        0xFFFFFF20 },
    { reaper.ImGui_Col_Header(),               0xFFFFFF14 },
    { reaper.ImGui_Col_HeaderHovered(),        0xFFFFFF1A },
    { reaper.ImGui_Col_HeaderActive(),         0xFFFFFF26 },
    { reaper.ImGui_Col_ScrollbarBg(),          0x00000000 },
    { reaper.ImGui_Col_ScrollbarGrab(),        0xFFFFFF22 },
    { reaper.ImGui_Col_ScrollbarGrabHovered(), 0xFFFFFF33 },
    { reaper.ImGui_Col_ScrollbarGrabActive(),  0xFFFFFF44 },
    { reaper.ImGui_Col_Separator(),            0xFFFFFF14 },
    { reaper.ImGui_Col_Button(),               0xFFFFFF14 },
    { reaper.ImGui_Col_ButtonHovered(),        0xFFFFFF22 },
    { reaper.ImGui_Col_ButtonActive(),         0xFFFFFF2E },
    { reaper.ImGui_Col_TitleBg(),              0x1F1F26FF },
    { reaper.ImGui_Col_TitleBgActive(),        0x26262EFF },
    { reaper.ImGui_Col_CheckMark(),            PA_GuiCol.ACCENT },
  }
  THEME_VARS = {
    { reaper.ImGui_StyleVar_WindowRounding(),    12 },
    { reaper.ImGui_StyleVar_WindowBorderSize(),  1 },
    { reaper.ImGui_StyleVar_WindowPadding(),     16, 14 },
    { reaper.ImGui_StyleVar_FrameRounding(),     9 },
    { reaper.ImGui_StyleVar_FramePadding(),      12, 9 },
    { reaper.ImGui_StyleVar_ItemSpacing(),       8, 8 },
    { reaper.ImGui_StyleVar_ScrollbarRounding(), 12 },
    { reaper.ImGui_StyleVar_ScrollbarSize(),     13 },
    { reaper.ImGui_StyleVar_PopupRounding(),     9 },
  }
end

-- Crée le contexte ImGui + les polices et initialise la lib. Retourne ctx.
function PA_GuiInit(name)
  ctx        = reaper.ImGui_CreateContext(name)
  font       = reaper.ImGui_CreateFont("sans-serif", 18)
  font_badge = reaper.ImGui_CreateFont("sans-serif", 11)
  reaper.ImGui_Attach(ctx, font)
  reaper.ImGui_Attach(ctx, font_badge)
  if not THEME_COLORS then buildTheme() end
  return ctx
end

-- ─── Frame : police + thème ─────────────────────────────────────────────

-- À appeler en tête de chaque frame (avant Begin), avec PA_GuiEndFrame en fin.
function PA_GuiBeginFrame()
  reaper.ImGui_PushFont(ctx, font, math.floor(PA_S(18) + 0.5))
  for _, v in ipairs(THEME_VARS) do
    if v[3] then reaper.ImGui_PushStyleVar(ctx, v[1], PA_S(v[2]), PA_S(v[3]))
    else         reaper.ImGui_PushStyleVar(ctx, v[1], PA_S(v[2])) end
  end
  for _, c in ipairs(THEME_COLORS) do
    reaper.ImGui_PushStyleColor(ctx, c[1], c[2])
  end
end

function PA_GuiEndFrame()
  reaper.ImGui_PopStyleColor(ctx, #THEME_COLORS)
  reaper.ImGui_PopStyleVar(ctx, #THEME_VARS)
  reaper.ImGui_PopFont(ctx)
end

-- ─── Mode compact ───────────────────────────────────────────────────────

-- Réduit tout ce qui est dessiné (police, styles, dimensions via PA_S)
-- jusqu'au PA_GuiEndCompact correspondant. Pensé pour les fenêtres
-- secondaires (paramètres) : à appeler entre PA_GuiBeginFrame et le Begin
-- de la fenêtre concernée. mult par défaut : 0.8 (~20 % plus petit).
function PA_GuiBeginCompact(mult)
  compact = mult or 0.8
  reaper.ImGui_PushFont(ctx, font, math.floor(PA_S(18) + 0.5))
  for _, v in ipairs(THEME_VARS) do
    if v[3] then reaper.ImGui_PushStyleVar(ctx, v[1], PA_S(v[2]), PA_S(v[3]))
    else         reaper.ImGui_PushStyleVar(ctx, v[1], PA_S(v[2])) end
  end
end

function PA_GuiEndCompact()
  reaper.ImGui_PopStyleVar(ctx, #THEME_VARS)
  reaper.ImGui_PopFont(ctx)
  compact = 1.0
end

-- ─── Placement de fenêtre (dimensions non scalées, la lib applique PA_S) ─

-- Prochaine fenêtre centrée sur la souris, bornée au viewport.
function PA_GuiWindowAtMouse(w, h)
  w, h = PA_S(w), PA_S(h)
  local vp = reaper.ImGui_GetMainViewport(ctx)
  local vx, vy = reaper.ImGui_Viewport_GetWorkPos(vp)
  local sw, sh = reaper.ImGui_Viewport_GetWorkSize(vp)
  local mx, my = reaper.GetMousePosition()
  local wx = math.max(vx, math.min(mx - w * 0.5, vx + sw - w))
  local wy = math.max(vy, math.min(my - h * 0.5, vy + sh - h))
  reaper.ImGui_SetNextWindowSize(ctx, w, h)
  reaper.ImGui_SetNextWindowPos(ctx, wx, wy, reaper.ImGui_Cond_Always())
end

-- Prochaine fenêtre centrée sur le viewport, avec offset optionnel (px écran).
function PA_GuiWindowCentered(w, h, dx, dy)
  w, h = PA_S(w), PA_S(h)
  local vp = reaper.ImGui_GetMainViewport(ctx)
  local vx, vy = reaper.ImGui_Viewport_GetWorkPos(vp)
  local sw, sh = reaper.ImGui_Viewport_GetWorkSize(vp)
  reaper.ImGui_SetNextWindowSize(ctx, w, h)
  reaper.ImGui_SetNextWindowPos(ctx, vx + (sw - w) * 0.5 + (dx or 0),
    vy + (sh - h) * 0.5 + (dy or 0), reaper.ImGui_Cond_Always())
end

-- Redimensionne la prochaine fenêtre sans la repositionner
-- (typiquement après un changement d'échelle).
function PA_GuiResizeWindow(w, h)
  reaper.ImGui_SetNextWindowSize(ctx, PA_S(w), PA_S(h))
end

-- ─── Widgets ────────────────────────────────────────────────────────────

-- Pastille arrondie ajoutée à la ligne courante (police badge).
-- bg/fg optionnels : pastille neutre par défaut.
function PA_GuiPill(text, bg, fg)
  bg, fg = bg or PA_GuiCol.PILL_BG, fg or PA_GuiCol.PILL_FG
  reaper.ImGui_SameLine(ctx)
  local pad_x, pad_y = PA_S(7), PA_S(3)
  local line_h = reaper.ImGui_GetTextLineHeight(ctx)
  reaper.ImGui_PushFont(ctx, font_badge, math.floor(PA_S(11) + 0.5))
  local tw = reaper.ImGui_CalcTextSize(ctx, text)
  local th = reaper.ImGui_GetTextLineHeight(ctx)
  local bw, bh = tw + pad_x * 2, th + pad_y * 2
  local cx, cy = reaper.ImGui_GetCursorScreenPos(ctx)
  local by = cy + (line_h - bh) * 0.5
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  reaper.ImGui_DrawList_AddRectFilled(dl, cx, by, cx + bw, by + bh, bg, bh * 0.5)
  reaper.ImGui_DrawList_AddText(dl, cx + pad_x, by + pad_y, fg, text)
  reaper.ImGui_PopFont(ctx)
  reaper.ImGui_Dummy(ctx, bw, line_h)
end

-- Titre de section des fenêtres de paramètres : SeparatorText si dispo
-- (ReaImGui récent), sinon un fallback équivalent.
function PA_GuiSection(label)
  if reaper.ImGui_SeparatorText then
    reaper.ImGui_SeparatorText(ctx, label)
  else
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Text(ctx, label)
    reaper.ImGui_Separator(ctx)
  end
end

-- Padding vertical réduit des checkboxes / radio buttons : la boîte reste
-- lisible mais moins haute que les champs de saisie du thème.
local CHECK_PAD_Y = 5

-- Checkbox à boîte réduite ; mêmes retours que ImGui_Checkbox.
function PA_GuiCheckbox(label, value)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(),
    PA_S(12), PA_S(CHECK_PAD_Y))
  local rv, nv = reaper.ImGui_Checkbox(ctx, label, value)
  reaper.ImGui_PopStyleVar(ctx)
  return rv, nv
end

-- Radio button à cercle réduit ; même retour que ImGui_RadioButton.
function PA_GuiRadioButton(label, active)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(),
    PA_S(12), PA_S(CHECK_PAD_Y))
  local rv = reaper.ImGui_RadioButton(ctx, label, active)
  reaper.ImGui_PopStyleVar(ctx)
  return rv
end

-- Texte d'erreur (rouge).
function PA_GuiErrorText(text)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), PA_GuiCol.ERROR_TEXT)
  reaper.ImGui_Text(ctx, text)
  reaper.ImGui_PopStyleColor(ctx)
end

-- Loupe dessinée au bord droit du dernier item (champ de recherche vide).
function PA_GuiSearchIcon()
  local _,   iy0 = reaper.ImGui_GetItemRectMin(ctx)
  local ix1, iy1 = reaper.ImGui_GetItemRectMax(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local mcx, mcy = ix1 - PA_S(22), (iy0 + iy1) * 0.5 - 1
  reaper.ImGui_DrawList_AddCircle(dl, mcx, mcy, PA_S(5), PA_GuiCol.ICON_DIM, 0, PA_S(1.6))
  reaper.ImGui_DrawList_AddLine(dl, mcx + PA_S(3.6), mcy + PA_S(3.6),
    mcx + PA_S(7.5), mcy + PA_S(7.5), PA_GuiCol.ICON_DIM, PA_S(1.6))
end

-- Bouton carré (hauteur de frame) avec engrenage dessiné. Retourne true si cliqué.
function PA_GuiGearButton(id)
  local sz = reaper.ImGui_GetFrameHeight(ctx)
  local clicked = reaper.ImGui_Button(ctx, id or "##pa_gui_gear", sz, sz)
  local bx0, by0 = reaper.ImGui_GetItemRectMin(ctx)
  local bx1, by1 = reaper.ImGui_GetItemRectMax(ctx)
  local gcx, gcy = (bx0 + bx1) * 0.5, (by0 + by1) * 0.5
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local col = reaper.ImGui_IsItemHovered(ctx) and PA_GuiCol.ICON_HOVER or PA_GuiCol.ICON
  local r_in, r_out = PA_S(4.5), PA_S(7.5)
  for k = 0, 7 do
    local a = k * (math.pi / 4) + math.pi / 8
    local ca, sa = math.cos(a), math.sin(a)
    reaper.ImGui_DrawList_AddLine(dl,
      gcx + ca * r_in,  gcy + sa * r_in,
      gcx + ca * r_out, gcy + sa * r_out, col, PA_S(2.6))
  end
  reaper.ImGui_DrawList_AddCircle(dl, gcx, gcy, r_in, col, 0, PA_S(2.2))
  return clicked
end

-- Bouton carré (hauteur de frame) avec croix dessinée (supprimer).
-- Dessiné à la main : les glyphes ✕/✎ n'existent pas dans toutes les polices.
function PA_GuiXButton(id)
  local sz = reaper.ImGui_GetFrameHeight(ctx)
  local clicked = reaper.ImGui_Button(ctx, id or "##pa_gui_x", sz, sz)
  local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
  local x1, y1 = reaper.ImGui_GetItemRectMax(ctx)
  local cx, cy = (x0 + x1) * 0.5, (y0 + y1) * 0.5
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local col = reaper.ImGui_IsItemHovered(ctx) and PA_GuiCol.ICON_HOVER or PA_GuiCol.ICON
  local r = PA_S(4.2)
  reaper.ImGui_DrawList_AddLine(dl, cx - r, cy - r, cx + r, cy + r, col, PA_S(2))
  reaper.ImGui_DrawList_AddLine(dl, cx - r, cy + r, cx + r, cy - r, col, PA_S(2))
  return clicked
end

-- Bouton carré (hauteur de frame) avec crayon dessiné (éditer).
function PA_GuiPencilButton(id)
  local sz = reaper.ImGui_GetFrameHeight(ctx)
  local clicked = reaper.ImGui_Button(ctx, id or "##pa_gui_pencil", sz, sz)
  local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
  local x1, y1 = reaper.ImGui_GetItemRectMax(ctx)
  local cx, cy = (x0 + x1) * 0.5, (y0 + y1) * 0.5
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local col = reaper.ImGui_IsItemHovered(ctx) and PA_GuiCol.ICON_HOVER or PA_GuiCol.ICON
  -- corps du crayon (diagonale) + pointe (triangle) en bas à gauche
  reaper.ImGui_DrawList_AddLine(dl, cx - PA_S(2.2), cy + PA_S(2.2),
    cx + PA_S(5.2), cy - PA_S(5.2), col, PA_S(2.6))
  reaper.ImGui_DrawList_AddTriangleFilled(dl,
    cx - PA_S(6.2), cy + PA_S(6.2),
    cx - PA_S(4.6), cy + PA_S(1.4),
    cx - PA_S(1.4), cy + PA_S(4.6), col)
  return clicked
end

local SCALE_OPTIONS = { 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0 }

-- Combo de choix d'échelle (persistée, partagée entre scripts).
-- Retourne true si l'échelle vient de changer.
function PA_GuiScaleCombo(id)
  local changed = false
  -- libellé le plus large + padding de frame + le carré de la flèche
  local combo_w = reaper.ImGui_CalcTextSize(ctx, "200 %") + PA_S(24) + reaper.ImGui_GetFrameHeight(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, combo_w)
  local cur = string.format("%d %%", math.floor(scale * 100 + 0.5))
  if reaper.ImGui_BeginCombo(ctx, id or "##pa_gui_scale", cur) then
    for _, s in ipairs(SCALE_OPTIONS) do
      local lbl = string.format("%d %%", math.floor(s * 100 + 0.5))
      if reaper.ImGui_Selectable(ctx, lbl, s == scale) and s ~= scale then
        PA_GuiSetScale(s)
        changed = true
      end
    end
    reaper.ImGui_EndCombo(ctx)
  end
  return changed
end
