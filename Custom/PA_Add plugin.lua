-- @description Add plugin to selected track (searchable list)
-- @author lepierrealain
-- @version 1.2
-- @provides [main] .
-- @requires js_ReaScriptAPI, ReaImGui

local lib_path = ({ reaper.get_action_context() })[2]:match("^(.+[\\/])")
local lib_root = lib_path .. ".." .. package.config:sub(1,1) .. "Libraries" .. package.config:sub(1,1)
dofile(lib_root .. "PA_lib_track.lua")

local ctx = reaper.ImGui_CreateContext("PA_AddPlugin")
local font       = reaper.ImGui_CreateFont("sans-serif", 18)
local font_badge = reaper.ImGui_CreateFont("sans-serif", 11)
reaper.ImGui_Attach(ctx, font)
reaper.ImGui_Attach(ctx, font_badge)

local EXT_SECTION = "PA_AddPlugin"

-- Tag lists: each entry drives load/save, prefix filtering, context menu, and inline tags
local TAGS = {
  { key = "instruments", label = "Instruments", prefix = "/i", list = {} },
  { key = "eq",  label = "EQ",  prefix = "/q", list = {} },
  { key = "compressor",  label = "Compressor",  prefix = "/c", list = {} },
  { key = "reverb",      label = "Reverb",      prefix = "/r", list = {} },
  { key = "saturation",  label = "Saturation",  prefix = "/s", list = {} },
  { key = "cleaning",    label = "Cleaning",    prefix = "/cl", list = {} },
  { key = "creative",    label = "Creative",    prefix = "/cr", list = {} },
}
local TAG_BY_KEY = {}
for _, t in ipairs(TAGS) do TAG_BY_KEY[t.key] = t end

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

-- Favorites (separate: different visual treatment)
local favorites = {}

local function loadFavorites()
  favorites = {}
  for name in reaper.GetExtState(EXT_SECTION, "favorites"):gmatch("([^|]+)") do
    favorites[name] = true
  end
end

local function saveFavorites()
  local parts = {}
  for name in pairs(favorites) do parts[#parts + 1] = name end
  reaper.SetExtState(EXT_SECTION, "favorites", table.concat(parts, "|"), true)
end

loadFavorites()
for _, t in ipairs(TAGS) do loadTag(t) end

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
local function formatRank(name)
  return FORMAT_ORDER[name:lower():match("^([a-z0-9]+):")] or 8
end

local function wordCount(name)
  local n = 0
  for _ in name:gmatch("%S+") do n = n + 1 end
  return n
end

local function sortByFormat(t, words)
  local nwords = #words
  table.sort(t, function(a, b)
    local ra, rb = formatRank(a), formatRank(b)
    if ra ~= rb then return ra < rb end
    if nwords > 0 then
      local wa = wordCount(a:gsub("^[^:]+:%s*", ""):gsub("%s*%b()%s*$", ""))
      local wb = wordCount(b:gsub("^[^:]+:%s*", ""):gsub("%s*%b()%s*$", ""))
      local ea, eb = (wa == nwords), (wb == nwords)
      if ea ~= eb then return ea end
    end
    return a:lower() < b:lower()
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
    local _, plugin, vendor = parseName(name)
    local key = (plugin .. "|" .. vendor):lower()
    if not best[key] or formatRank(name) < formatRank(best[key]) then
      best[key] = name
    end
  end
  local result = {}
  for _, name in ipairs(list) do
    local _, plugin, vendor = parseName(name)
    local key = (plugin .. "|" .. vendor):lower()
    if best[key] == name then result[#result + 1] = name end
  end
  return result
end

local function rebuildFiltered(query)
  filtered = {}
  local q = query:lower()
  local active_tag = nil
  for _, t in ipairs(TAGS) do
    if q:sub(1, #t.prefix) == t.prefix then
      active_tag = t
      q = q:sub(#t.prefix + 1):match("^%s*(.-)%s*$") or ""
      break
    end
  end

  local words = {}
  for w in q:gmatch("%S+") do words[#words + 1] = w end
  local favs_name, favs_vendor, name_match, vendor_only = {}, {}, {}, {}

  for _, name in ipairs(all_plugins) do
    local nl = name:lower()
    local tag_ok = not active_tag or active_tag.list[name] == true
    if tag_ok and (q == "" or matchesAllWords(nl, words)) then
      local without_vendor = nl:gsub("%s*%b()%s*$", "")
      local matches_name = q == "" or matchesAllWords(without_vendor, words)
      if favorites[name] then
        if matches_name then favs_name[#favs_name + 1] = name
        else                 favs_vendor[#favs_vendor + 1] = name end
      else
        if matches_name then name_match[#name_match + 1] = name
        else                 vendor_only[#vendor_only + 1] = name end
      end
    end
  end

  sortByFormat(favs_name, words);  sortByFormat(favs_vendor, words)
  sortByFormat(name_match, words); sortByFormat(vendor_only, words)

  favs_name   = deduplicateByFormat(favs_name)
  favs_vendor = deduplicateByFormat(favs_vendor)
  name_match  = deduplicateByFormat(name_match)
  vendor_only = deduplicateByFormat(vendor_only)

  for _, n in ipairs(favs_name)   do filtered[#filtered + 1] = n end
  for _, n in ipairs(favs_vendor) do filtered[#filtered + 1] = n end
  for _, n in ipairs(name_match)  do filtered[#filtered + 1] = n end
  for _, n in ipairs(vendor_only) do filtered[#filtered + 1] = n end

  selected_idx       = 1
  scroll_to_selected = true
end

rebuildFiltered(filter_buf)

local function isInstrument(plugin_name)
  local p = plugin_name:lower()
  return p:find("^vsti:") or p:find("^vst3i:") or p:find("^clapi:")
end

local function addPlugin(plugin_name)
  local track = reaper.GetSelectedTrack(0, 0)
  if not track then
    reaper.ShowMessageBox("No track selected.", "Add Plugin", 0)
    return
  end
  reaper.Undo_BeginBlock()
  reaper.TrackFX_AddByName(track, plugin_name, false, -1)
  if isInstrument(plugin_name) then PA_SetTrackTemplateToMidi() end
  reaper.Undo_EndBlock("Add plugin: " .. plugin_name, -1)
end

local win_init        = true
local focus_on_open   = true

local function loop()
  reaper.ImGui_PushFont(ctx, font, 18)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowRounding(),    10)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(),     14, 14)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(),     8)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(),      10, 7)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(),       8, 8)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ScrollbarRounding(), 8)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_CheckMark(),       0xAAAAAAAAFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgHovered(),  0x55555588)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgActive(),   0x66666699)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderHovered(),   0x55555566)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Header(),          0x44444455)

  if win_init then
    if mini_mode then
      local mx, my = reaper.GetMousePosition()
      local sw, sh = reaper.ImGui_Viewport_GetSize(reaper.ImGui_GetMainViewport(ctx))
      local wx = math.max(0, math.min(mx - MINI_W * 0.5, sw - MINI_W))
      local wy = math.max(0, math.min(my - MINI_H * 0.5, sh - MINI_H))
      reaper.ImGui_SetNextWindowSize(ctx, MINI_W, MINI_H)
      reaper.ImGui_SetNextWindowPos(ctx, wx, wy, reaper.ImGui_Cond_Always())
    else
      local sw, sh = reaper.ImGui_Viewport_GetSize(reaper.ImGui_GetMainViewport(ctx))
      reaper.ImGui_SetNextWindowSize(ctx, FULL_W, FULL_H)
      reaper.ImGui_SetNextWindowPos(ctx, (sw - FULL_W) * 0.5 + 150, (sh - FULL_H) * 0.5 + 100, reaper.ImGui_Cond_Always())
    end
    win_init = false
  end

  local visible = reaper.ImGui_Begin(ctx, "Add Plugin", nil,
    reaper.ImGui_WindowFlags_NoCollapse() | reaper.ImGui_WindowFlags_NoNav() | reaper.ImGui_WindowFlags_NoTitleBar())
  local open = true

  if not visible then
    reaper.ImGui_End(ctx)
    reaper.ImGui_PopStyleColor(ctx, 5)
    reaper.ImGui_PopStyleVar(ctx, 6)
    reaper.ImGui_PopFont(ctx)
    reaper.defer(loop)
    return
  end

  if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) or
     not reaper.ImGui_IsWindowFocused(ctx, reaper.ImGui_FocusedFlags_AnyWindow()) then
    open = false
  end

  if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_DownArrow()) then
    selected_idx = math.min(selected_idx + 1, math.max(1, #filtered))
    scroll_to_selected = true
  elseif reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_UpArrow()) then
    selected_idx = math.max(selected_idx - 1, 1)
    scroll_to_selected = true
  elseif reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter()) or
         reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_KeypadEnter()) then
    if filtered[selected_idx] then
      addPlugin(filtered[selected_idx])
      open = false
    end
  end

  if focus_on_open then
    reaper.ImGui_SetKeyboardFocusHere(ctx)
    focus_on_open = false
  end
  reaper.ImGui_SetNextItemWidth(ctx, -1)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgHovered(), 0x444444FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgActive(),  0x555555FF)
  local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
  local sx, sy = reaper.ImGui_GetCursorScreenPos(ctx)
  local fw = reaper.ImGui_GetContentRegionAvail(ctx)
  local fp_y = 7
  local fh = reaper.ImGui_GetTextLineHeight(ctx) + fp_y * 2
  reaper.ImGui_DrawList_AddRectFilled(draw_list, sx, sy, sx + fw, sy + fh, 0x444444FF, 8)
  reaper.ImGui_PopStyleColor(ctx, 2)
  local changed, new_val = reaper.ImGui_InputText(ctx, "##search", filter_buf,
    reaper.ImGui_InputTextFlags_AutoSelectAll())
  if changed then
    filter_buf = new_val
    rebuildFiltered(filter_buf)
  end

  reaper.ImGui_Spacing(ctx)
  if not mini_mode then
    reaper.ImGui_TextDisabled(ctx, #filtered .. " / " .. #all_plugins .. " plugins")
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_TextDisabled(ctx, "   [↑↓ Enter]")
    local active_tag = nil
    for _, t in ipairs(TAGS) do
      if filter_buf:lower():sub(1, #t.prefix) == t.prefix then active_tag = t; break end
    end
    if active_tag then
      reaper.ImGui_SameLine(ctx)
      reaper.ImGui_TextDisabled(ctx, "  " .. active_tag.prefix .. " " .. active_tag.label)
    end
    reaper.ImGui_Spacing(ctx)
  end

  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), 8, 10)
  if reaper.ImGui_BeginChild(ctx, "##list", 0, -1) then
    for i, name in ipairs(filtered) do
      local is_sel = (i == selected_idx)
      if scroll_to_selected and is_sel then
        reaper.ImGui_SetScrollHereY(ctx, 0.5)
        scroll_to_selected = false
      end

      local is_fav = favorites[name] == true
      local fmt, plugin, vendor = parseName(name)
      local row_x = reaper.ImGui_GetCursorPosX(ctx)
      local avail  = reaper.ImGui_GetContentRegionAvail(ctx)

      if reaper.ImGui_Selectable(ctx, "##sel" .. i, is_sel,
          reaper.ImGui_SelectableFlags_None(), avail, 0) then
        addPlugin(name)
        open = false
      end


      if is_fav then
        local rx0, ry0 = reaper.ImGui_GetItemRectMin(ctx)
        local rx1, ry1 = reaper.ImGui_GetItemRectMax(ctx)
        local dl = reaper.ImGui_GetWindowDrawList(ctx)
        reaper.ImGui_DrawList_AddRectFilled(dl, rx0, ry0, rx1, ry1, 0xFFDD4418, 6)
      end

      -- right-click context menu
      if reaper.ImGui_BeginPopupContextItem(ctx, "##ctx" .. i) then
        if is_fav then
          if reaper.ImGui_MenuItem(ctx, "Retirer de Favs") then
            favorites[name] = nil; saveFavorites(); rebuildFiltered(filter_buf)
          end
        else
          if reaper.ImGui_MenuItem(ctx, "Ajouter à Favs") then
            favorites[name] = true; saveFavorites(); rebuildFiltered(filter_buf)
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
      reaper.ImGui_SetCursorPosX(ctx, row_x + 8)

      if is_fav then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFDD88FF)
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
        reaper.ImGui_SameLine(ctx)
        local pad_x, pad_y = 6, 3
        local main_line_h = reaper.ImGui_GetTextLineHeight(ctx)
        reaper.ImGui_PushFont(ctx, font_badge, 11)
        local tw = reaper.ImGui_CalcTextSize(ctx, fmt)
        local bh = reaper.ImGui_GetTextLineHeight(ctx) + pad_y * 2
        local bw = tw + pad_x * 2
        reaper.ImGui_PopFont(ctx)
        local cx, cy = reaper.ImGui_GetCursorScreenPos(ctx)
        local _, ry0 = reaper.ImGui_GetItemRectMin(ctx)
        local _, ry1 = reaper.ImGui_GetItemRectMax(ctx)
        local dl = reaper.ImGui_GetWindowDrawList(ctx)
        local by = ry0 + (ry1 - ry0 - bh) * 0.5
        reaper.ImGui_DrawList_AddRectFilled(dl, cx, by, cx + bw, by + bh, 0x66666688, 6)
        reaper.ImGui_PushFont(ctx, font_badge, 11)
        reaper.ImGui_DrawList_AddText(dl, cx + pad_x, by + pad_y, 0xBBBBBBFF, fmt)
        reaper.ImGui_PopFont(ctx)
        reaper.ImGui_Dummy(ctx, bw, main_line_h)
      end

      -- inline tags (hidden in mini mode)
      if not mini_mode then
        for _, t in ipairs(TAGS) do
          if t.list[name] then
            reaper.ImGui_SameLine(ctx)
            reaper.ImGui_TextDisabled(ctx, "[" .. t.label .. "]")
          end
        end
      end
    end
    reaper.ImGui_EndChild(ctx)
  end
  reaper.ImGui_PopStyleVar(ctx)

  reaper.ImGui_End(ctx)
  reaper.ImGui_PopStyleColor(ctx, 5)
  reaper.ImGui_PopStyleVar(ctx, 6)
  reaper.ImGui_PopFont(ctx)

  if open then reaper.defer(loop) end
end

reaper.defer(loop)
