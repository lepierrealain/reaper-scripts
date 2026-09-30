-- @description Add plugin to selected track (searchable list)
-- @author lepierrealain
-- @version 2.0
-- @provides [main] .
-- @requires js_ReaScriptAPI, ReaImGui

local lib_path = ({ reaper.get_action_context() })[2]:match("^(.+[\\/])")
local lib_root = lib_path .. ".." .. package.config:sub(1,1) .. "Libraries" .. package.config:sub(1,1)
dofile(lib_root .. "PA_lib_track.lua")
dofile(lib_root .. "PA_lib_gui.lua")

local ctx     = PA_GuiInit("PA_AddPlugin")
local clipper = reaper.ImGui_CreateListClipper(ctx)

local EXT_SECTION = "PA_AddPlugin"

local S = PA_S
local scale_dirty = false  -- resize the window on the frame after a scale change

-- Tag lists: each entry drives load/save, prefix filtering, context menu, and inline tags.
-- Created and edited by the user in the settings window; persisted in ext state.
local TAGS = {}
local TAGS_BY_PREFIX = {}

-- Longest prefix wins so /cl (cleaning) and /cr (creative) beat /c (compressor)
local function rebuildTagPrefixes()
  TAGS_BY_PREFIX = {}
  for _, t in ipairs(TAGS) do TAGS_BY_PREFIX[#TAGS_BY_PREFIX + 1] = t end
  table.sort(TAGS_BY_PREFIX, function(a, b) return #a.prefix > #b.prefix end)
end

local function saveCategories()
  local recs = {}
  for _, t in ipairs(TAGS) do
    recs[#recs + 1] = t.key .. "\31" .. t.label .. "\31" .. t.prefix
  end
  reaper.SetExtState(EXT_SECTION, "categories", table.concat(recs, "\30"), true)
end

local function loadCategories()
  TAGS = {}
  for rec in reaper.GetExtState(EXT_SECTION, "categories"):gmatch("[^\30]+") do
    local key, label, prefix = rec:match("^([^\31]+)\31([^\31]*)\31([^\31]+)$")
    if key then TAGS[#TAGS + 1] = { key = key, label = label, prefix = prefix, list = {} } end
  end
  rebuildTagPrefixes()
end

local function matchTagPrefix(q)
  for _, t in ipairs(TAGS_BY_PREFIX) do
    if q:sub(1, #t.prefix) == t.prefix then return t end
  end
end

local function loadTag(t)
  t.list = {}
  for name in reaper.GetExtState(EXT_SECTION, t.key):gmatch("([^|]+)") do
    t.list[name] = true
  end
end

local function saveTag(t)
  local parts = {}
  for name in pairs(t.list) do parts[#parts + 1] = name end
  reaper.SetExtState(EXT_SECTION, t.key, table.concat(parts, "|"), true)
end

-- Favorites (separate: different visual treatment + manual ordering via drag & drop)
local favorites       = {}  -- set: name -> true
local favorites_order = {}  -- array: user-defined display order

local function loadFavorites()
  favorites, favorites_order = {}, {}
  for name in reaper.GetExtState(EXT_SECTION, "favorites"):gmatch("([^|]+)") do
    if not favorites[name] then
      favorites[name] = true
      favorites_order[#favorites_order + 1] = name
    end
  end
end

local function saveFavorites()
  reaper.SetExtState(EXT_SECTION, "favorites", table.concat(favorites_order, "|"), true)
end

local function addFavorite(name)
  if favorites[name] then return end
  favorites[name] = true
  favorites_order[#favorites_order + 1] = name
  saveFavorites()
end

local function removeFavorite(name)
  favorites[name] = nil
  for k, n in ipairs(favorites_order) do
    if n == name then table.remove(favorites_order, k) break end
  end
  saveFavorites()
end

loadCategories()
for _, t in ipairs(TAGS) do loadTag(t) end
loadFavorites()

-- Build plugin list once at startup
local function buildPluginList()
  local list = {}
  local i = 0
  while true do
    local ok, name = reaper.EnumInstalledFX(i)
    if not ok then break end
    list[#list + 1] = name
    i = i + 1
  end
  table.sort(list, function(a, b) return a:lower() < b:lower() end)
  return list
end

local all_plugins = buildPluginList()

-- Allow caller to pre-set filter via ext state
local _init_filter = reaper.GetExtState(EXT_SECTION, "init_filter")
local mini_mode    = reaper.GetExtState(EXT_SECTION, "init_mini") == "1"
reaper.DeleteExtState(EXT_SECTION, "init_filter", false)
reaper.DeleteExtState(EXT_SECTION, "init_mini",   false)

local MINI_W, MINI_H = 400, 400
local FULL_W, FULL_H = 800, 600

local filter_buf         = _init_filter or ""
local filtered           = {}
local selected_idx       = 1
local scroll_to_selected = false

-- "VSTi: Kontakt (8 out) (Native Instruments)" → fmt="VSTi", plugin="Kontakt (8 out)", vendor="Native Instruments"
local function isTechSuffix(s)
  if s:match("^%d+%s+%a+$")  then return true end
  if s:match("^%d+[io]%d*$") then return true end
  if s:match("^%d+%s*ch$")   then return true end
  if s:match("^%d+%s*out$")  then return true end
  if s:match("^%a+$") and #s <= 6 then return true end
  return false
end

local function parseName(name)
  local fmt  = name:match("^([^:]+):")
  local rest = name:match("^[^:]+:%s*(.+)$") or name
  local plugin, vendor = rest, ""
  local pos = #rest
  while pos >= 1 do
    if rest:sub(pos, pos) ~= ")" then break end
    local depth, group_end, open_i = 0, pos, nil
    for i = pos, 1, -1 do
      local c = rest:sub(i, i)
      if c == ")" then depth = depth + 1
      elseif c == "(" then
        depth = depth - 1
        if depth == 0 then open_i = i; break end
      end
    end
    if not open_i or open_i <= 1 then break end
    local content = rest:sub(open_i + 1, group_end - 1)
    if not isTechSuffix(content) then
      vendor = content
      plugin = rest:sub(1, open_i - 1):match("^(.-)%s*$")
      return fmt or "", plugin, vendor
    end
    pos = open_i - 2
  end
  return fmt or "", plugin, vendor
end

local FORMAT_ORDER = { clapi=1, clap=2, vst3i=3, vst3=4, vsti=5, vst=6, js=7 }

local function wordCount(name)
  local n = 0
  for _ in name:gmatch("%S+") do n = n + 1 end
  return n
end

-- Extract a product family and its numeric version, e.g. "Kontakt 8".
-- Newer releases are then sorted ahead of older ones within each format.
local function extractVersionInfo(plugin)
  local family, version = plugin:lower():match("^(.-)%s+[vV]?(%d[%d%.]*)")
  if not family then return "", nil end

  family = family:match("^%s*(.-)%s*$")
  local parts = {}
  for part in version:gmatch("%d+") do parts[#parts + 1] = tonumber(part) end
  return family, parts
end

-- Precomputed per-plugin data: parsed parts, dedup key, sort keys, filter strings
local INFO = {}
local function buildInfo()
  INFO = {}
  for _, name in ipairs(all_plugins) do
    local fmt, plugin, vendor = parseName(name)
    local nl = name:lower()
    local version_family, version_parts = extractVersionInfo(plugin)
    INFO[name] = {
      fmt = fmt, plugin = plugin, vendor = vendor,
      key = (plugin .. "|" .. vendor):lower(),
      lower = nl,
      lower_no_vendor = nl:gsub("%s*%b()%s*$", ""),
      rank = FORMAT_ORDER[nl:match("^([a-z0-9]+):")] or 8,
      words = wordCount(nl:gsub("^[^:]+:%s*", ""):gsub("%s*%b()%s*$", "")),
      version_family = version_family,
      version_parts = version_parts,
    }
  end
end
buildInfo()

local function newerVersionFirst(a, b)
  if not a.version_parts or not b.version_parts
      or a.version_family == "" or a.version_family ~= b.version_family then
    return nil
  end

  local count = math.max(#a.version_parts, #b.version_parts)
  for i = 1, count do
    local av, bv = a.version_parts[i] or 0, b.version_parts[i] or 0
    if av ~= bv then return av > bv end
  end
  return nil
end

local function sortByFormat(t, words)
  local nwords = #words
  table.sort(t, function(a, b)
    local ia, ib = INFO[a], INFO[b]
    if ia.rank ~= ib.rank then return ia.rank < ib.rank end
    if nwords > 0 then
      local ea, eb = (ia.words == nwords), (ib.words == nwords)
      if ea ~= eb then return ea end
    end
    local newer = newerVersionFirst(ia, ib)
    if newer ~= nil then return newer end
    return ia.lower < ib.lower
  end)
end

local function matchesAllWords(str, words)
  for _, w in ipairs(words) do
    if not str:find(w, 1, true) then return false end
  end
  return true
end

local function deduplicateByFormat(list)
  local best = {}  -- canonical_key -> best full name
  for _, name in ipairs(list) do
    local info = INFO[name]
    local b = best[info.key]
    if not b or info.rank < INFO[b].rank then best[info.key] = name end
  end
  local result = {}
  for _, name in ipairs(list) do
    if best[INFO[name].key] == name then result[#result + 1] = name end
  end
  return result
end

local function rebuildFiltered(query)
  filtered = {}
  local q = query:lower()
  local active_tag = matchTagPrefix(q)
  if active_tag then
    q = q:sub(#active_tag.prefix + 1):match("^%s*(.-)%s*$") or ""
  end

  local words = {}
  for w in q:gmatch("%S+") do words[#words + 1] = w end
  local favs, name_match, vendor_only = {}, {}, {}

  -- favorites keep their user-defined order (drag & drop), always on top
  for _, name in ipairs(favorites_order) do
    local info = INFO[name]  -- nil if the plugin is no longer installed
    if info and (not active_tag or active_tag.list[name] == true)
        and (q == "" or matchesAllWords(info.lower, words)) then
      favs[#favs + 1] = name
    end
  end

  for _, name in ipairs(all_plugins) do
    if not favorites[name] then
      local info = INFO[name]
      local tag_ok = not active_tag or active_tag.list[name] == true
      if tag_ok and (q == "" or matchesAllWords(info.lower, words)) then
        if q == "" or matchesAllWords(info.lower_no_vendor, words) then
          name_match[#name_match + 1] = name
        else
          vendor_only[#vendor_only + 1] = name
        end
      end
    end
  end

  sortByFormat(name_match, words); sortByFormat(vendor_only, words)

  favs        = deduplicateByFormat(favs)
  name_match  = deduplicateByFormat(name_match)
  vendor_only = deduplicateByFormat(vendor_only)

  for _, n in ipairs(favs)        do filtered[#filtered + 1] = n end
  for _, n in ipairs(name_match)  do filtered[#filtered + 1] = n end
  for _, n in ipairs(vendor_only) do filtered[#filtered + 1] = n end

  selected_idx       = 1
  scroll_to_selected = true
end

rebuildFiltered(filter_buf)

-- Re-enumerate installed FX without restarting REAPER (after a plugin rescan)
local function rescanPlugins()
  all_plugins = buildPluginList()
  buildInfo()
  rebuildFiltered(filter_buf)
end

local function isInstrument(plugin_name)
  local p = plugin_name:lower()
  return p:find("^vsti:") or p:find("^vst3i:") or p:find("^clapi:")
end

local function addPlugin(plugin_name)
  local track = reaper.GetSelectedTrack(0, 0)
  if not track then
    reaper.ShowMessageBox("No track selected.", "Add Plugin", 0)
    return false
  end
  reaper.Undo_BeginBlock()
  local fx_idx = reaper.TrackFX_AddByName(track, plugin_name, false, -1)
  if fx_idx >= 0 and isInstrument(plugin_name) then PA_SetTrackTemplateToMidi() end
  reaper.Undo_EndBlock("Add plugin: " .. plugin_name, -1)
  if fx_idx < 0 then
    reaper.ShowMessageBox("Failed to add plugin:\n" .. plugin_name, "Add Plugin", 0)
    return false
  end
  return true
end

-- Alt+Enter: add to the active take of every selected item
local function addPluginToItems(plugin_name)
  local n = reaper.CountSelectedMediaItems(0)
  if n == 0 then
    reaper.ShowMessageBox("No item selected.", "Add Plugin", 0)
    return false
  end
  if n > 1 then
    local ret = reaper.ShowMessageBox(
      n .. " items sélectionnés.\nAjouter « " .. plugin_name .. " » à tous ?",
      "Add Plugin", 4)
    if ret ~= 6 then return false end
  end
  reaper.Undo_BeginBlock()
  local added = false
  for i = 0, n - 1 do
    local take = reaper.GetActiveTake(reaper.GetSelectedMediaItem(0, i))
    if take and reaper.TakeFX_AddByName(take, plugin_name, -1) >= 0 then
      added = true
    end
  end
  reaper.Undo_EndBlock("Add plugin to items: " .. plugin_name, -1)
  if not added then
    reaper.ShowMessageBox("Failed to add plugin:\n" .. plugin_name, "Add Plugin", 0)
    return false
  end
  reaper.UpdateArrange()
  return true
end

-- Shift+Enter: add to the selected track's input FX chain
local function addPluginToInputFX(plugin_name)
  local track = reaper.GetSelectedTrack(0, 0)
  if not track then
    reaper.ShowMessageBox("No track selected.", "Add Plugin", 0)
    return false
  end
  reaper.Undo_BeginBlock()
  local fx_idx = reaper.TrackFX_AddByName(track, plugin_name, true, -1)
  reaper.Undo_EndBlock("Add plugin to input FX: " .. plugin_name, -1)
  if fx_idx < 0 then
    reaper.ShowMessageBox("Failed to add plugin:\n" .. plugin_name, "Add Plugin", 0)
    return false
  end
  return true
end

-- Dispatch on the modifiers held at the moment of the Enter press / click
local function addPluginWithMods(plugin_name)
  local mods = reaper.ImGui_GetKeyMods(ctx)
  if mods & reaper.ImGui_Mod_Alt() ~= 0 then
    return addPluginToItems(plugin_name)
  elseif mods & reaper.ImGui_Mod_Shift() ~= 0 then
    return addPluginToInputFX(plugin_name)
  end
  return addPlugin(plugin_name)
end

-- ─── Theme (shared palette from PA_lib_gui) ─────────────────────────────
local ACCENT, ACCENT_BG, HOVER_BG = PA_GuiCol.ACCENT, PA_GuiCol.ACCENT_BG, PA_GuiCol.HOVER_BG
local GOLD, GOLD_TEXT, GOLD_BG    = PA_GuiCol.GOLD, PA_GuiCol.GOLD_TEXT, PA_GuiCol.GOLD_BG
local TAG_PILL_BG, TAG_PILL_FG    = PA_GuiCol.PILL_BG, PA_GuiCol.PILL_FG

-- Plugin-format badge colors (specific to this script)
local FMT_STYLE = {
  clap  = { fg = 0x4FD6BEFF, bg = 0x4FD6BE26 },
  clapi = { fg = 0x4FD6BEFF, bg = 0x4FD6BE26 },
  vst3  = { fg = 0x9D8CFFFF, bg = 0x9D8CFF26 },
  vst3i = { fg = 0x9D8CFFFF, bg = 0x9D8CFF26 },
  vst   = { fg = 0x8FA3BFFF, bg = 0x8FA3BF26 },
  vsti  = { fg = 0x8FA3BFFF, bg = 0x8FA3BF26 },
  js    = { fg = 0x8BD17CFF, bg = 0x8BD17C26 },
}
local FMT_DEFAULT = { fg = 0xAAAAAAFF, bg = 0xFFFFFF16 }

local drawPill = PA_GuiPill

-- ─── Settings window ────────────────────────────────────────────────────
local show_settings  = false
local cat_name_buf   = ""
local cat_prefix_buf = ""
local cat_error      = nil
local edit_idx       = nil   -- index of the category being edited in place
local edit_name_buf, edit_prefix_buf = "", ""
local edit_error     = nil

-- ext state keys used for other things than a category's plugin list
local RESERVED_KEYS = {
  favorites = true, categories = true, ui_scale = true,
  init_filter = true, init_mini = true,
}

local function categoryKeyExists(key)
  if RESERVED_KEYS[key] then return true end
  for _, t in ipairs(TAGS) do
    if t.key == key then return true end
  end
  return false
end

-- Normalizes and checks a name/prefix pair; skip_idx excludes a category from
-- the uniqueness check (when editing itself). Returns label, prefix or nil, nil, error.
local function validateCategory(label, prefix, skip_idx)
  label  = label:match("^%s*(.-)%s*$")
  prefix = prefix:gsub("%s+", ""):lower()
  if label == "" then return nil, nil, "Le nom est vide." end
  if prefix ~= "" and prefix:sub(1, 1) ~= "/" then prefix = "/" .. prefix end
  if prefix == "" or prefix == "/" then return nil, nil, "Le préfixe est vide." end
  for k, t in ipairs(TAGS) do
    if k ~= skip_idx and t.prefix == prefix then
      return nil, nil, "Préfixe déjà utilisé par « " .. t.label .. " »."
    end
  end
  return label, prefix
end

-- Returns an error string, or nil on success
local function addCategory(label, prefix)
  local lbl, pfx, err = validateCategory(label, prefix, nil)
  if err then return err end
  local key = lbl:lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
  if key == "" then key = "cat" end
  local base, n = key, 1
  while categoryKeyExists(key) do n = n + 1; key = base .. "_" .. n end
  TAGS[#TAGS + 1] = { key = key, label = lbl, prefix = pfx, list = {} }
  rebuildTagPrefixes()
  saveCategories()
  rebuildFiltered(filter_buf)
end

-- Returns an error string, or nil on success
local function editCategory(idx, label, prefix)
  local lbl, pfx, err = validateCategory(label, prefix, idx)
  if err then return err end
  -- key (ext state storage) intentionally unchanged: tagged plugins are preserved
  TAGS[idx].label, TAGS[idx].prefix = lbl, pfx
  rebuildTagPrefixes()
  saveCategories()
  rebuildFiltered(filter_buf)
end

local function removeCategory(idx)
  local t = table.remove(TAGS, idx)
  if not t then return end
  reaper.DeleteExtState(EXT_SECTION, t.key, true)
  rebuildTagPrefixes()
  saveCategories()
  rebuildFiltered(filter_buf)
end

local function drawSettingsWindow()
  -- Fenêtre secondaire : rendue ~20 % plus petite que la fenêtre principale
  PA_GuiBeginCompact()
  local vp = reaper.ImGui_GetMainViewport(ctx)
  local vx, vy = reaper.ImGui_Viewport_GetWorkPos(vp)
  local sw, sh = reaper.ImGui_Viewport_GetWorkSize(vp)
  reaper.ImGui_SetNextWindowPos(ctx, vx + sw * 0.5, vy + sh * 0.5,
    reaper.ImGui_Cond_Appearing(), 0.5, 0.5)
  -- Largeur fixe, hauteur automatique : les lignes s'alignent en colonnes
  -- au lieu de faire varier la largeur à chaque édition
  reaper.ImGui_SetNextWindowSizeConstraints(ctx, S(430), 0, S(430), 16384)
  local s_visible, s_open = reaper.ImGui_Begin(ctx, "Paramètres", true,
    reaper.ImGui_WindowFlags_NoCollapse() | reaper.ImGui_WindowFlags_AlwaysAutoResize())
  if not s_open then show_settings = false end
  if not s_visible then PA_GuiEndCompact() return end

  PA_GuiSection("Interface")
  reaper.ImGui_Text(ctx, "Taille de l'interface")
  reaper.ImGui_SameLine(ctx)
  if PA_GuiScaleCombo() then scale_dirty = true end

  PA_GuiSection("Catégories")
  if #TAGS == 0 then
    reaper.ImGui_TextDisabled(ctx, "Aucune catégorie — créez-en une ci-dessous.")
  end
  local to_remove
  local btn_sz    = reaper.ImGui_GetFrameHeight(ctx)
  local win_w     = reaper.ImGui_GetWindowWidth(ctx)
  local actions_x = win_w - S(16) - btn_sz * 2 - S(6)  -- 2 boutons alignés à droite
  for idx, t in ipairs(TAGS) do
    reaper.ImGui_PushID(ctx, idx)
    if edit_idx == idx then
      local _
      reaper.ImGui_SetNextItemWidth(ctx, S(150))
      _, edit_name_buf = reaper.ImGui_InputTextWithHint(ctx, "##editname", "Nom", edit_name_buf)
      reaper.ImGui_SameLine(ctx)
      reaper.ImGui_SetNextItemWidth(ctx, S(60))
      _, edit_prefix_buf = reaper.ImGui_InputTextWithHint(ctx, "##editprefix", "/x", edit_prefix_buf)
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_Button(ctx, "OK##editok") then
        edit_error = editCategory(idx, edit_name_buf, edit_prefix_buf)
        if not edit_error then edit_idx = nil end
      end
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_Button(ctx, "Annuler##editcancel") then
        edit_idx, edit_error = nil, nil
      end
      if edit_error then PA_GuiErrorText(edit_error) end
    else
      reaper.ImGui_AlignTextToFramePadding(ctx)
      reaper.ImGui_Text(ctx, t.label)
      drawPill(t.prefix, TAG_PILL_BG, TAG_PILL_FG)
      reaper.ImGui_SameLine(ctx)
      reaper.ImGui_SetCursorPosX(ctx, actions_x)
      if PA_GuiPencilButton("##edit") then
        edit_idx, edit_error = idx, nil
        edit_name_buf, edit_prefix_buf = t.label, t.prefix
      end
      reaper.ImGui_SameLine(ctx, 0, S(6))
      if PA_GuiXButton("##del") then to_remove = idx end
    end
    reaper.ImGui_PopID(ctx)
  end
  if to_remove then
    removeCategory(to_remove)
    if edit_idx == to_remove then edit_idx = nil
    elseif edit_idx and edit_idx > to_remove then edit_idx = edit_idx - 1 end
  end

  reaper.ImGui_Spacing(ctx)
  -- Nom extensible, préfixe fixe, "Ajouter" calé au bord droit
  local aj_w  = reaper.ImGui_CalcTextSize(ctx, "Ajouter") + S(24)
  local avail = reaper.ImGui_GetContentRegionAvail(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, avail - S(70) - aj_w - S(16))
  local _
  _, cat_name_buf = reaper.ImGui_InputTextWithHint(ctx, "##catname", "Nom", cat_name_buf)
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, S(70))
  _, cat_prefix_buf = reaper.ImGui_InputTextWithHint(ctx, "##catprefix", "/x", cat_prefix_buf)
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, "Ajouter") then
    cat_error = addCategory(cat_name_buf, cat_prefix_buf)
    if not cat_error then cat_name_buf, cat_prefix_buf = "", "" end
  end
  if cat_error then PA_GuiErrorText(cat_error) end

  PA_GuiSection("Plugins")
  reaper.ImGui_TextDisabled(ctx, #all_plugins .. " plugins détectés")
  if reaper.ImGui_Button(ctx, "Mettre à jour la liste des plugins") then
    rescanPlugins()
  end

  reaper.ImGui_End(ctx)
  PA_GuiEndCompact()
end

local win_init        = true
local focus_on_open   = true

local function loop()
  PA_GuiBeginFrame()

  if win_init then
    if mini_mode then PA_GuiWindowAtMouse(MINI_W, MINI_H)
    else              PA_GuiWindowCentered(FULL_W, FULL_H, 150, 100) end
    win_init = false
  elseif scale_dirty then
    -- new scale: resize the window, keep its position
    if mini_mode then PA_GuiResizeWindow(MINI_W, MINI_H)
    else              PA_GuiResizeWindow(FULL_W, FULL_H) end
    scale_dirty = false
  end

  local visible = reaper.ImGui_Begin(ctx, "Add Plugin", nil,
    reaper.ImGui_WindowFlags_NoCollapse() | reaper.ImGui_WindowFlags_NoNav() | reaper.ImGui_WindowFlags_NoTitleBar())
  local open = true

  if not visible then
    reaper.ImGui_End(ctx)
    PA_GuiEndFrame()
    reaper.defer(loop)
    return
  end

  if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
    if show_settings then show_settings = false else open = false end
  elseif not reaper.ImGui_IsWindowFocused(ctx, reaper.ImGui_FocusedFlags_AnyWindow()) then
    open = false
  end

  -- keyboard nav only while the main window (not settings) has focus
  if reaper.ImGui_IsWindowFocused(ctx, reaper.ImGui_FocusedFlags_RootAndChildWindows()) then
    if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_DownArrow()) then
      selected_idx = math.min(selected_idx + 1, math.max(1, #filtered))
      scroll_to_selected = true
    elseif reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_UpArrow()) then
      selected_idx = math.max(selected_idx - 1, 1)
      scroll_to_selected = true
    elseif reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter()) or
           reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_KeypadEnter()) then
      if filtered[selected_idx] and addPluginWithMods(filtered[selected_idx]) then
        open = false
      end
    end
  end

  if focus_on_open then
    reaper.ImGui_SetKeyboardFocusHere(ctx)
    focus_on_open = false
  end
  -- square settings button, exactly as tall as the search field
  local gear_sz = reaper.ImGui_GetFrameHeight(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, -(gear_sz + S(8)))
  local changed, new_val = reaper.ImGui_InputTextWithHint(ctx, "##search",
    "Rechercher un plugin…", filter_buf, reaper.ImGui_InputTextFlags_AutoSelectAll())
  if changed then
    filter_buf = new_val
    rebuildFiltered(filter_buf)
  end

  -- magnifier glyph, drawn at the right edge while the field is empty
  if filter_buf == "" then PA_GuiSearchIcon() end

  reaper.ImGui_SameLine(ctx)
  if PA_GuiGearButton("##settings") then
    show_settings = not show_settings
  end

  reaper.ImGui_Spacing(ctx)
  if not mini_mode then
    reaper.ImGui_TextDisabled(ctx, #filtered .. " / " .. #all_plugins .. " plugins")
    local active_tag = matchTagPrefix(filter_buf:lower())
    if active_tag then
      drawPill(active_tag.prefix .. "  " .. active_tag.label, ACCENT_BG, PA_GuiCol.ACCENT_TEXT)
    end
    -- keyboard hint, right-aligned
    local hint = "↑↓ naviguer  ·  Entrée piste  ·  Alt+Entrée item  ·  Maj+Entrée input FX"
    reaper.ImGui_SameLine(ctx)
    local avail_w = reaper.ImGui_GetContentRegionAvail(ctx)
    local hint_w = reaper.ImGui_CalcTextSize(ctx, hint)
    if avail_w > hint_w then
      reaper.ImGui_SetCursorPosX(ctx, reaper.ImGui_GetCursorPosX(ctx) + avail_w - hint_w)
      reaper.ImGui_TextDisabled(ctx, hint)
    else
      reaper.ImGui_NewLine(ctx)
    end
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)
  end

  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), S(8), S(10))
  if reaper.ImGui_BeginChild(ctx, "##list", 0, -1) then
    -- Selectables inflate their rect by ItemSpacing.y/2 on each side; leave room
    -- at the top so row 1's highlight isn't clipped by the child window edge
    reaper.ImGui_SetCursorPosY(ctx, reaper.ImGui_GetCursorPosY(ctx) + S(5))
    local rows = filtered  -- menu actions rebuild `filtered` mid-frame; keep this frame's list stable
    if #rows == 0 then
      -- empty state: submit real content so EndChild has an item to size against
      reaper.ImGui_SetCursorPosX(ctx, reaper.ImGui_GetCursorPosX(ctx) + S(12))
      reaper.ImGui_TextDisabled(ctx, "Aucun plugin trouvé")
    end
    reaper.ImGui_ListClipper_Begin(clipper, #rows)
    if scroll_to_selected and rows[selected_idx] then
      reaper.ImGui_ListClipper_IncludeItemByIndex(clipper, selected_idx - 1)
    end
    while reaper.ImGui_ListClipper_Step(clipper) do
      local d_start, d_end = reaper.ImGui_ListClipper_GetDisplayRange(clipper)
      for i = d_start + 1, d_end do
        local name = rows[i]
        local is_sel = (i == selected_idx)
        if scroll_to_selected and is_sel then
          reaper.ImGui_SetScrollHereY(ctx, 0.5)
          scroll_to_selected = false
        end

        local is_fav = favorites[name] == true
        local info = INFO[name]
        local fmt, plugin, vendor = info.fmt, info.plugin, info.vendor
        local row_x = reaper.ImGui_GetCursorPosX(ctx)
        local avail  = reaper.ImGui_GetContentRegionAvail(ctx)

        -- hide the Selectable's own highlight: the row is custom-drawn below
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Header(),        0x00000000)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderHovered(), 0x00000000)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderActive(),  0x00000000)
        -- favorites host a drag grip on top of the row, hence AllowOverlap
        local sel_flags = is_fav and reaper.ImGui_SelectableFlags_AllowOverlap()
                                  or reaper.ImGui_SelectableFlags_None()
        if reaper.ImGui_Selectable(ctx, "##sel" .. i, is_sel, sel_flags, avail, 0) then
          if addPluginWithMods(name) then open = false end
        end
        reaper.ImGui_PopStyleColor(ctx, 3)

        -- custom row background: favorite wash, then selection/hover on top
        local rx0, ry0 = reaper.ImGui_GetItemRectMin(ctx)
        local rx1, ry1 = reaper.ImGui_GetItemRectMax(ctx)
        local row_dl = reaper.ImGui_GetWindowDrawList(ctx)
        if is_fav then
          reaper.ImGui_DrawList_AddRectFilled(row_dl, rx0, ry0, rx1, ry1, GOLD_BG, S(7))
        end
        if is_sel then
          reaper.ImGui_DrawList_AddRectFilled(row_dl, rx0, ry0, rx1, ry1, ACCENT_BG, S(7))
          reaper.ImGui_DrawList_AddRectFilled(row_dl, rx0, ry0 + S(4), rx0 + S(3), ry1 - S(4), ACCENT, S(2))
        elseif reaper.ImGui_IsItemHovered(ctx) then
          reaper.ImGui_DrawList_AddRectFilled(row_dl, rx0, ry0, rx1, ry1, HOVER_BG, S(7))
        end

        -- right-click context menu
        if reaper.ImGui_BeginPopupContextItem(ctx, "##ctx" .. i) then
          if is_fav then
            if reaper.ImGui_MenuItem(ctx, "Retirer de Favs") then
              removeFavorite(name); rebuildFiltered(filter_buf)
            end
          else
            if reaper.ImGui_MenuItem(ctx, "Ajouter à Favs") then
              addFavorite(name); rebuildFiltered(filter_buf)
            end
          end
          for _, t in ipairs(TAGS) do
            if t.list[name] then
              if reaper.ImGui_MenuItem(ctx, "Retirer de " .. t.label) then
                t.list[name] = nil; saveTag(t); rebuildFiltered(filter_buf)
              end
            else
              if reaper.ImGui_MenuItem(ctx, "Ajouter à " .. t.label) then
                t.list[name] = true; saveTag(t); rebuildFiltered(filter_buf)
              end
            end
          end
          reaper.ImGui_EndPopup(ctx)
        end

        reaper.ImGui_SameLine(ctx)
        reaper.ImGui_SetCursorPosX(ctx, row_x + S(12))

        if is_fav then
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), GOLD)
          reaper.ImGui_Text(ctx, "★")
          reaper.ImGui_PopStyleColor(ctx)
          reaper.ImGui_SameLine(ctx)
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), GOLD_TEXT)
          reaper.ImGui_Text(ctx, plugin)
          reaper.ImGui_PopStyleColor(ctx)
        else
          reaper.ImGui_Text(ctx, plugin)
        end

        if vendor ~= "" then
          reaper.ImGui_SameLine(ctx)
          reaper.ImGui_TextDisabled(ctx, vendor)
        end

        if fmt ~= "" then
          local style = FMT_STYLE[fmt:lower()] or FMT_DEFAULT
          drawPill(fmt, style.bg, style.fg)
        end

        -- inline tags (hidden in mini mode)
        if not mini_mode then
          for _, t in ipairs(TAGS) do
            if t.list[name] then
              drawPill(t.label, TAG_PILL_BG, TAG_PILL_FG)
            end
          end
        end

        -- drag grip to reorder favorites (ID keyed on the plugin name so the
        -- active drag follows the row when it swaps positions)
        if is_fav then
          reaper.ImGui_SameLine(ctx)
          local grip_w = S(22)
          local line_h = reaper.ImGui_GetTextLineHeight(ctx)
          reaper.ImGui_SetCursorPosX(ctx, row_x + avail - grip_w - S(4))
          reaper.ImGui_InvisibleButton(ctx, "##grip" .. name, grip_w, line_h)
          local gx0, gy0 = reaper.ImGui_GetItemRectMin(ctx)
          local gx1, gy1 = reaper.ImGui_GetItemRectMax(ctx)
          local g_hov = reaper.ImGui_IsItemHovered(ctx)
          local g_act = reaper.ImGui_IsItemActive(ctx)
          local g_col = g_act and 0xFFFFFF99 or (g_hov and 0xFFFFFF55 or 0xFFFFFF26)
          local gcx, gcy = (gx0 + gx1) * 0.5, (gy0 + gy1) * 0.5
          for off = -1, 1 do
            local ly = gcy + off * S(4)
            reaper.ImGui_DrawList_AddLine(row_dl, gcx - S(5), ly, gcx + S(5), ly, g_col, S(1.4))
          end
          if g_hov or g_act then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeNS())
          end
          if g_act then
            local _, my = reaper.ImGui_GetMousePos(ctx)
            local j
            if my < ry0 and i > 1 and favorites[rows[i - 1]] then
              j = i - 1
            elseif my > ry1 and rows[i + 1] and favorites[rows[i + 1]] then
              j = i + 1
            end
            if j then
              local other = rows[j]
              rows[i], rows[j] = rows[j], rows[i]
              local a_idx, b_idx
              for k, n2 in ipairs(favorites_order) do
                if n2 == name then a_idx = k elseif n2 == other then b_idx = k end
              end
              if a_idx and b_idx then
                favorites_order[a_idx], favorites_order[b_idx] =
                  favorites_order[b_idx], favorites_order[a_idx]
                saveFavorites()
              end
              if selected_idx == i then selected_idx = j
              elseif selected_idx == j then selected_idx = i end
            end
          end
        end
      end
    end
    reaper.ImGui_EndChild(ctx)
  end
  reaper.ImGui_PopStyleVar(ctx)

  reaper.ImGui_End(ctx)

  if show_settings then drawSettingsWindow() end

  PA_GuiEndFrame()

  if open then reaper.defer(loop) end
end

reaper.defer(loop)
