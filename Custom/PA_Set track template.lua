-- @description Set track record template (MIDI / audio inputs)
-- @author lepierrealain
-- @version 1.5
-- @provides [main] .
-- @requires js_ReaScriptAPI, ReaImGui

local lib_path = ({ reaper.get_action_context() })[2]:match("^(.+[\\/])")
local lib_root = lib_path .. ".." .. package.config:sub(1,1) .. "Libraries" .. package.config:sub(1,1)
dofile(lib_root .. "PA_lib_track.lua")
dofile(lib_root .. "PA_lib_gui.lua")

local ctx = PA_GuiInit("Set Track Template")

-- Navigation au clavier : flèches pour se déplacer, Entrée/Espace pour valider
local cfg_flags = reaper.ImGui_GetConfigVar(ctx, reaper.ImGui_ConfigVar_Flags())
reaper.ImGui_SetConfigVar(ctx, reaper.ImGui_ConfigVar_Flags(),
  cfg_flags | reaper.ImGui_ConfigFlags_NavEnableKeyboard())

local EXT_SECTION = "PA_SetTrackTemplate"

-- ─── Inputs audio disponibles : mono puis paires stéréo ──────────────────

-- Chaque option porte sa valeur I_RECINPUT (canal 0-based, | 1024 pour une
-- paire stéréo) et le nom des canaux de la carte son.
local input_options = {}
do
  local n = reaper.GetNumAudioInputs()
  for ch = 0, n - 1 do
    input_options[#input_options + 1] = {
      recinput = ch,
      label    = "Input " .. (ch + 1),
      desc     = reaper.GetInputChannelName(ch),
    }
  end
  for ch = 0, n - 2, 2 do
    input_options[#input_options + 1] = {
      recinput = 1024 | ch,
      label    = ("Input %d/%d"):format(ch + 1, ch + 2),
      desc     = reaper.GetInputChannelName(ch) .. " / " .. reaper.GetInputChannelName(ch + 1),
    }
  end
end

-- Inputs cochés dans les paramètres, persistés en CSV de valeurs I_RECINPUT.
local enabled = {}
do
  local csv = reaper.GetExtState(EXT_SECTION, "inputs")
  if csv == "" then csv = "0,1" end  -- Input 1 et Input 2 mono par défaut
  for v in csv:gmatch("[^,]+") do
    local rec = tonumber(v)
    if rec then enabled[rec] = true end
  end
end

local function saveEnabled()
  local parts = {}
  for _, opt in ipairs(input_options) do
    if enabled[opt.recinput] then parts[#parts + 1] = tostring(opt.recinput) end
  end
  reaper.SetExtState(EXT_SECTION, "inputs", table.concat(parts, ","), true)
end

-- ─── Lignes du menu principal ────────────────────────────────────────────

local templates

local function rebuildTemplates()
  templates = { { label = "MIDI", fn = PA_SetTrackTemplateToMidi } }
  for _, opt in ipairs(input_options) do
    if enabled[opt.recinput] then
      local rec = opt.recinput
      templates[#templates + 1] = {
        label       = opt.label,
        pa_fn       = function() PA_SetTrackTemplateToInput(rec) end,
        guest_fn    = function() PA_SetTrackTemplateToGuestInput(rec) end,
        talkback_fn = function() PA_SetTrackTemplateToTalkbackInput(rec) end,
        idle_fn     = function() PA_SetTrackTemplateToInputIdle(rec) end,
      }
    end
  end
end

rebuildTemplates()

local WIN_W             = 430
local LABEL_GAP         = 24  -- espace entre le libellé et le premier bouton
local BTN_PAD           = 6   -- frame padding vertical réduit (boutons moins hauts)
local BTN_MARGIN        = 26  -- marge ajoutée au texte pour la largeur d'un bouton
local ROW_H             = 38  -- frame 30 (police 18 + 2 × BTN_PAD) + item spacing 8
local MAX_SETTINGS_ROWS = 10  -- au-delà : scroll dans la fenêtre

local win_init      = true
local focus_init    = true
local settings_open = false
local resize_h      = nil  -- hauteur (non scalée) à appliquer à la prochaine frame

local function windowHeight()
  if settings_open then
    return (1 + math.min(#input_options, MAX_SETTINGS_ROWS)) * ROW_H + 35
  end
  return #templates * ROW_H + 35
end

local function loop()
  PA_GuiBeginFrame()

  if win_init then
    PA_GuiWindowAtMouse(WIN_W, windowHeight())
    win_init = false
  elseif resize_h then
    PA_GuiResizeWindow(WIN_W, resize_h)
    resize_h = nil
  end

  local visible = reaper.ImGui_Begin(ctx, "Set Track Template", nil,
    reaper.ImGui_WindowFlags_NoCollapse() |
    reaper.ImGui_WindowFlags_NoTitleBar() | reaper.ImGui_WindowFlags_NoResize())
  local open = true

  if visible then
    -- Boutons un peu plus compacts que le thème partagé
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), PA_S(10), PA_S(BTN_PAD))

    if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
      if settings_open then
        settings_open = false
        resize_h = windowHeight()
      else
        open = false
      end
    end
    if not reaper.ImGui_IsWindowFocused(ctx, reaper.ImGui_FocusedFlags_AnyWindow()) then
      open = false
    end

    local gear_w = reaper.ImGui_GetFrameHeight(ctx)

    if settings_open then
      -- ── Paramètres : inputs à afficher dans le menu ──
      reaper.ImGui_AlignTextToFramePadding(ctx)
      reaper.ImGui_Text(ctx, "Inputs to display")
      reaper.ImGui_SameLine(ctx)
      local avail = reaper.ImGui_GetContentRegionAvail(ctx)
      reaper.ImGui_Dummy(ctx, avail - gear_w - PA_S(8), 0)
      reaper.ImGui_SameLine(ctx)
      if PA_GuiGearButton("##settings") then
        settings_open = false
        resize_h = windowHeight()
      end

      for _, opt in ipairs(input_options) do
        local label = opt.label
        if opt.desc and opt.desc ~= "" and opt.desc ~= " / " then
          label = label .. "  —  " .. opt.desc
        end
        local changed, checked = reaper.ImGui_Checkbox(ctx,
          label .. "##opt" .. opt.recinput, enabled[opt.recinput] or false)
        if changed then
          enabled[opt.recinput] = checked or nil
          saveEnabled()
          rebuildTemplates()
        end
      end
    else
      -- ── Menu principal ──
      local function apply(fn, undo_label)
        reaper.Undo_BeginBlock()
        fn()
        reaper.Undo_EndBlock(undo_label, -1)
        reaper.UpdateArrange()
        open = false
      end

      -- Colonne des libellés alignée sur le plus large
      local row_x = reaper.ImGui_GetCursorPosX(ctx)
      local label_w = 0
      for _, t in ipairs(templates) do
        if t.pa_fn then
          local w = reaper.ImGui_CalcTextSize(ctx, t.label)
          label_w = math.max(label_w, w)
        end
      end
      local btn_x = row_x + label_w + PA_S(LABEL_GAP)

      -- Boutons dimensionnés sur leur texte (le dernier remplit le reste)
      local function btnW(label)
        local w = reaper.ImGui_CalcTextSize(ctx, label)
        return w + PA_S(BTN_MARGIN)
      end
      local self_w, guest_w, talk_w = btnW("Self"), btnW("Guest"), btnW("Talkback")

      for _, t in ipairs(templates) do
        if t.pa_fn then
          reaper.ImGui_AlignTextToFramePadding(ctx)
          reaper.ImGui_Text(ctx, t.label)
          reaper.ImGui_SameLine(ctx, btn_x)
          if focus_init then reaper.ImGui_SetKeyboardFocusHere(ctx); focus_init = false end
          if reaper.ImGui_Button(ctx, "Self##" .. t.label, self_w, 0) then
            apply(t.pa_fn, "Set track template: " .. t.label .. " (Self)")
          end
          reaper.ImGui_SameLine(ctx)
          if reaper.ImGui_Button(ctx, "Guest##" .. t.label, guest_w, 0) then
            apply(t.guest_fn, "Set track template: " .. t.label .. " (Guest)")
          end
          reaper.ImGui_SameLine(ctx)
          if reaper.ImGui_Button(ctx, "Talkback##" .. t.label, talk_w, 0) then
            apply(t.talkback_fn, "Set track template: " .. t.label .. " (Talkback)")
          end
          reaper.ImGui_SameLine(ctx)
          if reaper.ImGui_Button(ctx, "Off##" .. t.label, -1, 0) then
            apply(t.idle_fn, "Set track template: " .. t.label .. " (idle)")
          end
        else
          if focus_init then reaper.ImGui_SetKeyboardFocusHere(ctx); focus_init = false end
          if reaper.ImGui_Button(ctx, t.label, -(gear_w + PA_S(8)), 0) then
            apply(t.fn, "Set track template: " .. t.label)
          end
          reaper.ImGui_SameLine(ctx)
          if PA_GuiGearButton("##settings") then
            settings_open = true
            resize_h = windowHeight()
          end
        end
      end
    end

    reaper.ImGui_PopStyleVar(ctx)
  end

  reaper.ImGui_End(ctx)
  PA_GuiEndFrame()

  if open then reaper.defer(loop) end
end

reaper.defer(loop)
