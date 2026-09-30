-- @description Automatically add regions from items: per-track settings
-- @author lepierrealain
-- @version 2.0
-- @requires ReaImGui
-- @about
--   Select the tracks to watch, then use each track's settings button to pick
--   its region mode and naming template. Modes: First item, All items, REAPER
--   Groups, and Close items. Naming supports $project, $track, $tracknumber,
--   $item and $itemnumber. Add zeroes after either number token to pad it,
--   e.g. $itemnumber000 produces 001 for the first item.

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

local WIN_W, WIN_H = 520, 560
local EXT_GUI = "PA_AutoRegion"
local win_init = true
local scale_dirty = false

local function loadWinSize()
  local w = tonumber(reaper.GetExtState(EXT_GUI, "win_w"))
  local h = tonumber(reaper.GetExtState(EXT_GUI, "win_h"))
  if w and h and w >= 420 and h >= 320 then return w, h end
  return WIN_W, WIN_H
end

local saved_w, saved_h = loadWinSize()

local function rememberWinSize()
  local w, h = reaper.ImGui_GetWindowSize(ctx)
  local uw, uh = w / PA_S(1), h / PA_S(1)
  if math.abs(uw - saved_w) > 2 or math.abs(uh - saved_h) > 2 then
    saved_w, saved_h = uw, uh
    reaper.SetExtState(EXT_GUI, "win_w", string.format("%.0f", uw), true)
    reaper.SetExtState(EXT_GUI, "win_h", string.format("%.0f", uh), true)
  end
end

local MODE_LABELS = { "First item", "All items", "Groups", "Close items" }
local COMBO_TO_MODE = {
  [0] = PA_AR_MODE_FIRST,
  [1] = PA_AR_MODE_ALL,
  [2] = PA_AR_MODE_GROUP,
  [3] = PA_AR_MODE_CLOSE,
}
local MODE_TO_COMBO = {
  [PA_AR_MODE_FIRST] = 0,
  [PA_AR_MODE_ALL]   = 1,
  [PA_AR_MODE_GROUP] = 2,
  [PA_AR_MODE_CLOSE] = 3,
}

local state = PA_AR_LoadState()
local ui_checks = {}
local ui_cfg = {}
local ui_tracks = {}

local editing_guid = nil
local edit_cfg = nil
local edit_gap = ""

local function buildTrackList()
  ui_tracks = {}
  local count = reaper.CountTracks(0)
  local depth = 0
  for i = 0, count - 1 do
    local track = reaper.GetTrack(0, i)
    local guid = reaper.GetTrackGUID(track)
    local _, name = reaper.GetTrackName(track)
    ui_tracks[#ui_tracks + 1] = {
      guid = guid, name = name, depth = depth, color = reaper.GetTrackColor(track),
    }
    local folder_depth = reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH")
    if folder_depth >= 1 then
      depth = depth + 1
    elseif folder_depth < 0 then
      depth = math.max(0, depth + folder_depth)
    end
  end
end

local function initializeUI()
  local watched = {}
  for _, guid in ipairs(state.guids) do watched[guid] = true end
  for _, track in ipairs(ui_tracks) do
    ui_checks[track.guid] = watched[track.guid] or false
    ui_cfg[track.guid] = PA_AR_CopyConfig(state.cfg[track.guid] or PA_AR_DefaultConfig())
  end
end

buildTrackList()
initializeUI()

local function trackByGuid(guid)
  for _, track in ipairs(ui_tracks) do
    if track.guid == guid then return track end
  end
end

local function openTrackSettings(guid)
  editing_guid = guid
  edit_cfg = PA_AR_CopyConfig(ui_cfg[guid] or PA_AR_DefaultConfig())
  edit_gap = string.format("%.9g", tonumber(edit_cfg.gap) or PA_AR_DEFAULT_GAP)
end

local function closeTrackSettings(save)
  if save and editing_guid and edit_cfg then
    local normalized_gap = edit_gap:gsub(",", ".")
    local gap = tonumber(normalized_gap) or PA_AR_DEFAULT_GAP
    edit_cfg.gap = math.max(0, gap)
    edit_cfg.naming = (edit_cfg.naming ~= "") and edit_cfg.naming
      or PA_AR_DefaultNaming(edit_cfg.mode)
    ui_cfg[editing_guid] = PA_AR_CopyConfig(edit_cfg)
  end
  editing_guid, edit_cfg, edit_gap = nil, nil, ""
end

local function collectIntoState()
  local selected, configs = {}, {}
  for _, track in ipairs(ui_tracks) do
    if ui_checks[track.guid] then
      selected[#selected + 1] = track.guid
      configs[track.guid] = PA_AR_CopyConfig(ui_cfg[track.guid] or PA_AR_DefaultConfig())
    end
  end
  state.guids = selected
  state.cfg = configs
end

local function drawTrackSettings()
  if not editing_guid or not edit_cfg then return end
  local track = trackByGuid(editing_guid)
  if not track or not ui_checks[editing_guid] then
    closeTrackSettings(false)
    return
  end

  PA_GuiBeginCompact()
  local viewport = reaper.ImGui_GetMainViewport(ctx)
  local vx, vy = reaper.ImGui_Viewport_GetWorkPos(viewport)
  local vw, vh = reaper.ImGui_Viewport_GetWorkSize(viewport)
  reaper.ImGui_SetNextWindowPos(ctx, vx + vw * 0.5, vy + vh * 0.5,
    reaper.ImGui_Cond_Appearing(), 0.5, 0.5)
  reaper.ImGui_SetNextWindowSizeConstraints(ctx, S(450), 0, S(500), 16384)

  local visible, open = reaper.ImGui_Begin(ctx, "Region settings — " .. track.name, true,
    reaper.ImGui_WindowFlags_NoCollapse() | reaper.ImGui_WindowFlags_AlwaysAutoResize())
  if not open then
    if visible then reaper.ImGui_End(ctx) end
    closeTrackSettings(false)
    PA_GuiEndCompact()
    return
  end
  if not visible then
    PA_GuiEndCompact()
    return
  end

  local avail_w = reaper.ImGui_GetContentRegionAvail(ctx)
  local segment_w = avail_w / #MODE_LABELS
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), 0, 0)
  for index, label in ipairs(MODE_LABELS) do
    local mode = COMBO_TO_MODE[index - 1]
    local active = edit_cfg.mode == mode
    if active then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x5B8CFF66)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x5B8CFF88)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0x5B8CFFAA)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), PA_GuiCol.ACCENT_TEXT)
    end
    if reaper.ImGui_Button(ctx, label .. "##mode_" .. index, segment_w, 0) then
      local old_mode = edit_cfg.mode
      if not edit_cfg.naming or edit_cfg.naming == PA_AR_DefaultNaming(old_mode) then
        edit_cfg.naming = PA_AR_DefaultNaming(mode)
      end
      edit_cfg.mode = mode
    end
    if active then reaper.ImGui_PopStyleColor(ctx, 4) end
    if index < #MODE_LABELS then reaper.ImGui_SameLine(ctx) end
  end
  reaper.ImGui_PopStyleVar(ctx)

  if edit_cfg.mode == PA_AR_MODE_GROUP or edit_cfg.mode == PA_AR_MODE_CLOSE then
    local child_changed, include_children = PA_GuiCheckbox("Include child tracks", edit_cfg.children)
    if child_changed then edit_cfg.children = include_children end
  end

  if edit_cfg.mode == PA_AR_MODE_CLOSE then
    reaper.ImGui_AlignTextToFramePadding(ctx)
    reaper.ImGui_Text(ctx, "Maximum gap")
    reaper.ImGui_SameLine(ctx, S(140))
    reaper.ImGui_SetNextItemWidth(ctx, S(80))
    local gap_changed, value = reaper.ImGui_InputText(ctx, "##gap", edit_gap)
    if gap_changed then edit_gap = value end
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_TextDisabled(ctx, "seconds")
  end

  PA_GuiSection("Naming")
  reaper.ImGui_SetNextItemWidth(ctx, -1)
  local naming_changed, naming = reaper.ImGui_InputText(ctx, "##naming",
    edit_cfg.naming or PA_AR_DefaultNaming(edit_cfg.mode))
  if naming_changed then edit_cfg.naming = naming end
  reaper.ImGui_TextDisabled(ctx, "$project  $track  $tracknumber  $item  $itemnumber")
  reaper.ImGui_TextDisabled(ctx, "Add 0s for padding: $itemnumber000 -> 001")

  reaper.ImGui_Spacing(ctx)
  if reaper.ImGui_Button(ctx, "Done", S(90), 0) then closeTrackSettings(true) end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, "Cancel", S(90), 0) then closeTrackSettings(false) end

  reaper.ImGui_End(ctx)
  PA_GuiEndCompact()
end

local function drawUI()
  PA_GuiSection("Tracks")
  reaper.ImGui_TextDisabled(ctx, "Check a track, then use its settings button.")

  local _, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
  -- Keep enough room for Refresh, the Apply section and its buttons.  The
  -- track list itself scrolls, so it may shrink on a short window instead of
  -- pushing the controls below the bottom edge.
  local footer_h = reaper.ImGui_GetFrameHeightWithSpacing(ctx) * 3
    + reaper.ImGui_GetTextLineHeightWithSpacing(ctx)
  local list_h = math.max(1, avail_h - footer_h)
  if reaper.ImGui_BeginChild(ctx, "##tracklist", 0, list_h) then
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), S(12), S(5))

    for _, track in ipairs(ui_tracks) do
      if track.depth > 0 then reaper.ImGui_Indent(ctx, track.depth * S(12)) end

      local has_color = track.color ~= 0
      if has_color then
        local r = (track.color >> 16) & 0xFF
        local g = (track.color >> 8) & 0xFF
        local b = track.color & 0xFF
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
          (r << 24) | (g << 16) | (b << 8) | 0xFF)
      end

      local changed, checked = reaper.ImGui_Checkbox(ctx,
        track.name .. "##check_" .. track.guid, ui_checks[track.guid])
      if changed then
        ui_checks[track.guid] = checked
        if checked and not ui_cfg[track.guid] then ui_cfg[track.guid] = PA_AR_DefaultConfig() end
        if not checked and editing_guid == track.guid then closeTrackSettings(false) end
      end

      if has_color then reaper.ImGui_PopStyleColor(ctx) end

      if ui_checks[track.guid] then
        reaper.ImGui_SameLine(ctx)
        local mode = ui_cfg[track.guid] and ui_cfg[track.guid].mode or PA_AR_MODE_FIRST
        local label = MODE_LABELS[(MODE_TO_COMBO[mode] or 0) + 1]
        reaper.ImGui_TextDisabled(ctx, label)
        reaper.ImGui_SameLine(ctx)
        if PA_GuiGearButton("##settings_" .. track.guid) then openTrackSettings(track.guid) end
      end

      if track.depth > 0 then reaper.ImGui_Unindent(ctx, track.depth * S(12)) end
    end

    reaper.ImGui_PopStyleVar(ctx)
    reaper.ImGui_EndChild(ctx)
  end

  if reaper.ImGui_Button(ctx, "Refresh tracks") then
    local old_checks, old_cfg = ui_checks, ui_cfg
    ui_checks, ui_cfg = {}, {}
    buildTrackList()
    for _, track in ipairs(ui_tracks) do
      ui_checks[track.guid] = old_checks[track.guid] or false
      ui_cfg[track.guid] = old_cfg[track.guid]
        and PA_AR_CopyConfig(old_cfg[track.guid]) or PA_AR_DefaultConfig()
    end
  end

  PA_GuiSection("Apply")
  if reaper.ImGui_Button(ctx, "Apply", S(110), 0) then
    -- Applying from the main window also validates an editor left open.
    if editing_guid then closeTrackSettings(true) end
    state = PA_AR_LoadState()
    collectIntoState()
    PA_AR_Resync(state)
    PA_AR_TouchStamp()
  end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, "Close", S(90), 0) then return true end
  reaper.ImGui_SameLine(ctx)
  if PA_GuiScaleCombo("##scale") then scale_dirty = true end
  return false
end

local function loop()
  PA_GuiBeginFrame()
  PA_GuiBeginCompact()
  if win_init then
    PA_GuiWindowAtMouse(saved_w, saved_h)
    win_init = false
  elseif scale_dirty then
    PA_GuiResizeWindow(saved_w, saved_h)
    scale_dirty = false
  end
  reaper.ImGui_SetNextWindowSizeConstraints(ctx, S(420), S(340), 16384, 16384)

  local visible, open = reaper.ImGui_Begin(ctx, "Auto region from items — settings", true,
    reaper.ImGui_WindowFlags_NoCollapse())
  if visible then
    rememberWinSize()
    if drawUI() then open = false end
    if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape())
      and not reaper.ImGui_IsPopupOpen(ctx, "", reaper.ImGui_PopupFlags_AnyPopup()) then
      if editing_guid then closeTrackSettings(false) else open = false end
    end
    reaper.ImGui_End(ctx)
  end
  PA_GuiEndCompact()

  if open then drawTrackSettings() end
  PA_GuiEndFrame()
  if open then reaper.defer(loop) end
end

reaper.defer(loop)
