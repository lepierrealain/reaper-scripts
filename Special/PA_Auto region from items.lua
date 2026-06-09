-- @description Automatically add region from items from tracks
-- @author lepierrealain
-- @version 2.1

local EXT_NS      = "AutoRegions"
local EXT_TRACKS  = "tracks"
local EXT_MAP     = "map"
local EXT_TITLE   = "title"
local EXT_CFG     = "cfg"     -- par piste : tguid|src|custom  (sans use_global/mode/padding → niveau projet)
local EXT_MODE    = "mode"    -- projet : mode|padding|sep

-- src   : 0=Track  1=Custom
-- mode  : 0=Itemname  1=Numbering  2=Single
local SRC_TRACK   = 0
local SRC_CUSTOM  = 1
local MODE_ITEM   = 0
local MODE_NUM    = 1
local MODE_SINGLE = 2

-- ─────────────────────────────────────────────
-- Utilitaires
-- ─────────────────────────────────────────────

local function split(str, sep)
  local result = {}
  for part in str:gmatch("[^" .. sep .. "]+") do
    result[#result + 1] = part
  end
  return result
end

local function trackGUID(track)  return reaper.GetTrackGUID(track)          end
local function itemGUID(item)    return reaper.BR_GetMediaItemGUID(item)     end

local function itemName(item)
  local take = reaper.GetActiveTake(item)
  if take then return reaper.GetTakeName(take) end
  return "Item"
end

local function trackName(track)
  local _, n = reaper.GetTrackName(track)
  return n
end

-- Formate un index avec zero-padding (padding = nombre de chiffres minimum)
local function formatNum(n, padding)
  return string.format("%0" .. tostring(math.max(1, padding)) .. "d", n)
end

-- ─────────────────────────────────────────────
-- Persistance
-- ─────────────────────────────────────────────

-- Encodage par piste : tguid|src|custom  (mode et padding sont au niveau projet)
local function encodeCfg(track_cfg)
  local parts = {}
  for tguid, c in pairs(track_cfg) do
    parts[#parts + 1] = table.concat({
      tguid,
      tostring(c.src),
      c.custom or "",
    }, "|")
  end
  return table.concat(parts, ";")
end

local function decodeCfg(str)
  local cfg = {}
  if not str or str == "" then return cfg end
  for _, entry in ipairs(split(str, ";")) do
    local tguid, src, custom = entry:match("^([^|]+)|([01])|(.*)")
    if tguid then
      cfg[tguid] = {
        src    = tonumber(src),
        custom = custom or "",
      }
    end
  end
  return cfg
end

local function saveState(watched_guids, item_to_region, track_cfg, title, single_regions, proj_mode, proj_padding, proj_sep)
  reaper.SetProjExtState(0, EXT_NS, EXT_TITLE,  title or "")
  reaper.SetProjExtState(0, EXT_NS, EXT_TRACKS, table.concat(watched_guids, "|"))
  reaper.SetProjExtState(0, EXT_NS, EXT_CFG,    encodeCfg(track_cfg))
  reaper.SetProjExtState(0, EXT_NS, EXT_MODE,
    tostring(proj_mode or MODE_ITEM) .. "|" .. tostring(proj_padding or 1) .. "|" .. (proj_sep or "_"))

  -- MAP : iguid:ridx pour les modes normaux ; tguid:ridx pour single mode (préfixe "T:")
  local parts = {}
  for guid, idx in pairs(item_to_region) do
    parts[#parts + 1] = guid .. ":" .. tostring(idx)
  end
  for tguid, idx in pairs(single_regions) do
    parts[#parts + 1] = "T:" .. tguid .. ":" .. tostring(idx)
  end
  reaper.SetProjExtState(0, EXT_NS, EXT_MAP, table.concat(parts, "|"))
end

local function loadState()
  local watched_guids  = {}
  local item_to_region = {}
  local single_regions = {}   -- tguid → region_idx  (single mode)
  local track_cfg      = {}
  local title          = ""
  local proj_mode      = MODE_ITEM
  local proj_padding   = 1

  local _, tracks_str = reaper.GetProjExtState(0, EXT_NS, EXT_TRACKS)
  if tracks_str and tracks_str ~= "" then watched_guids = split(tracks_str, "|") end

  local _, map_str = reaper.GetProjExtState(0, EXT_NS, EXT_MAP)
  if map_str and map_str ~= "" then
    for _, pair in ipairs(split(map_str, "|")) do
      if pair:sub(1, 2) == "T:" then
        local tguid, idx = pair:sub(3):match("^(.+):(%d+)$")
        if tguid and idx then single_regions[tguid] = tonumber(idx) end
      else
        local guid, idx = pair:match("^(.+):(%d+)$")
        if guid and idx then item_to_region[guid] = tonumber(idx) end
      end
    end
  end

  local _, cfg_str = reaper.GetProjExtState(0, EXT_NS, EXT_CFG)
  track_cfg = decodeCfg(cfg_str)

  local _, t = reaper.GetProjExtState(0, EXT_NS, EXT_TITLE)
  if t and t ~= "" then title = t end

  local _, mode_str = reaper.GetProjExtState(0, EXT_NS, EXT_MODE)
  if mode_str and mode_str ~= "" then
    local m, p, s = mode_str:match("^(%d+)|(%d+)|(.*)$")
    if m then
      proj_mode    = tonumber(m) or MODE_ITEM
      proj_padding = tonumber(p) or 1
      proj_sep     = (s and s ~= "") and s or "_"
    end
  end

  return watched_guids, item_to_region, track_cfg, title, single_regions, proj_mode, proj_padding, proj_sep
end

-- ─────────────────────────────────────────────
-- Snapshot
-- ─────────────────────────────────────────────

-- Retourne deux tables :
--   snapshot      iguid → { pos, len, name }   pour modes Item name + Numbering
--   single_snap   tguid → { pos, len, name }   pour Single mode
local function buildSnapshot(watched_guids, track_cfg, title, proj_mode, proj_padding, proj_sep)
  local watched_set = {}
  for _, g in ipairs(watched_guids) do watched_set[g] = true end

  local snapshot     = {}
  local single_snap  = {}
  local has_title    = title and title ~= ""
  local sep          = (proj_sep and proj_sep ~= "") and proj_sep or "_"

  local num_tracks = reaper.CountTracks(0)
  for t = 0, num_tracks - 1 do
    local track = reaper.GetTrack(0, t)
    local tguid = trackGUID(track)
    if not watched_set[tguid] then goto continue end

    local cfg = track_cfg[tguid]
    if not cfg then goto continue end

    local items = {}
    for i = 0, reaper.GetTrackNumMediaItems(track) - 1 do
      local item = reaper.GetTrackMediaItem(track, i)
      items[#items + 1] = {
        guid = itemGUID(item),
        pos  = reaper.GetMediaItemInfo_Value(item, "D_POSITION"),
        len  = reaper.GetMediaItemInfo_Value(item, "D_LENGTH"),
        name = itemName(item),
      }
    end

    local middle
    if cfg.src == SRC_TRACK then
      middle = trackName(track)
    else
      middle = (cfg.custom and cfg.custom ~= "") and cfg.custom or nil
    end

    local function make_name(suffix)
      local p = {}
      if has_title then p[#p + 1] = title end
      if middle    then p[#p + 1] = middle end
      if suffix    then p[#p + 1] = suffix end
      return table.concat(p, sep)
    end

    if proj_mode == MODE_ITEM then
      for _, item in ipairs(items) do
        snapshot[item.guid] = { pos = item.pos, len = item.len, name = make_name(item.name) }
      end

    elseif proj_mode == MODE_NUM then
      local count   = #items
      local padding = proj_padding or 1
      local needed  = #tostring(count)
      if needed > padding then padding = needed end
      for idx, item in ipairs(items) do
        snapshot[item.guid] = { pos = item.pos, len = item.len, name = make_name(formatNum(idx, padding)) }
      end

    elseif proj_mode == MODE_SINGLE then
      if #items > 0 then
        local first = items[1]
        single_snap[tguid] = { pos = first.pos, len = first.len, name = make_name(nil) }
      end
    end

    ::continue::
  end

  return snapshot, single_snap
end

-- ─────────────────────────────────────────────
-- Diff
-- ─────────────────────────────────────────────

local function applyDiff(prev, curr, item_to_region, prev_single, curr_single, single_regions)
  local dirty = false

  -- Modes normaux (Item name + Numbering) : supprimer/créer/modifier
  for guid in pairs(prev) do
    if not curr[guid] then
      local idx = item_to_region[guid]
      if idx then
        reaper.DeleteProjectMarker(0, idx, true)
        item_to_region[guid] = nil
        dirty = true
      end
    end
  end
  for guid, data in pairs(curr) do
    if not prev[guid] then
      local idx = reaper.AddProjectMarker2(0, true, data.pos, data.pos + data.len, data.name, -1, 0)
      item_to_region[guid] = idx
      dirty = true
    end
  end
  for guid, data in pairs(curr) do
    if prev[guid] then
      local p = prev[guid]
      if p.pos ~= data.pos or p.len ~= data.len or p.name ~= data.name then
        local idx = item_to_region[guid]
        if idx then
          reaper.SetProjectMarker4(0, idx, true, data.pos, data.pos + data.len, data.name, 0, 0)
          dirty = true
        end
      end
    end
  end

  -- Single mode : créer si absent, déplacer/renommer si présent, ne jamais supprimer
  for tguid, data in pairs(curr_single) do
    local idx = single_regions[tguid]
    if not idx then
      -- Créer
      idx = reaper.AddProjectMarker2(0, true, data.pos, data.pos + data.len, data.name, -1, 0)
      single_regions[tguid] = idx
      dirty = true
    else
      local p = prev_single[tguid]
      if not p or p.pos ~= data.pos or p.len ~= data.len or p.name ~= data.name then
        reaper.SetProjectMarker4(0, idx, true, data.pos, data.pos + data.len, data.name, 0, 0)
        dirty = true
      end
    end
  end

  return dirty
end

-- ─────────────────────────────────────────────
-- UI ImGui
-- ─────────────────────────────────────────────

local ctx              = nil
local ui_open          = false
local ui_title         = ""
local ui_mode          = MODE_ITEM   -- mode projet
local ui_padding_str   = "1"         -- padding projet (pour Numbering)
local ui_sep           = "_"         -- séparateur projet
local ui_checks        = {}   -- tguid → bool
local ui_cfg           = {}   -- tguid → { src, custom }
local ui_tracks        = {}   -- liste ordonnée { guid, name, depth, color }

local MODE_LABELS = { "Item name", "Numbering", "Single mode" }

local function buildTrackList()
  ui_tracks = {}
  local n = reaper.CountTracks(0)
  local depth = 0
  for i = 0, n - 1 do
    local track  = reaper.GetTrack(0, i)
    local guid   = trackGUID(track)
    local _, name = reaper.GetTrackName(track)
    local color  = reaper.GetTrackColor(track)
    ui_tracks[#ui_tracks + 1] = { guid = guid, name = name, depth = depth, color = color }
    local fd = reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH")
    if fd >= 1 then depth = depth + 1
    elseif fd < 0 then depth = math.max(0, depth + fd) end
  end
end

local function openConfigUI(watched_guids, track_cfg, title, proj_mode, proj_padding, proj_sep)
  buildTrackList()
  local watched_set = {}
  for _, g in ipairs(watched_guids) do watched_set[g] = true end
  ui_title       = title or ""
  ui_mode        = proj_mode or MODE_ITEM
  ui_padding_str = tostring(proj_padding or 1)
  ui_sep         = proj_sep or "_"
  ui_checks      = {}
  ui_cfg         = {}
  for _, t in ipairs(ui_tracks) do
    ui_checks[t.guid] = watched_set[t.guid] or false
    local c = track_cfg[t.guid]
    ui_cfg[t.guid] = {
      src    = c and c.src or SRC_TRACK,
      custom = c and c.custom or "",
    }
  end
  ui_open = true
end

local function tickConfigUI()
  if not ui_open then return nil end

  if not ctx then
    local font = reaper.ImGui_CreateFont("sans-serif", 15)
    ctx = reaper.ImGui_CreateContext("AutoRegionFromItems")
    reaper.ImGui_Attach(ctx, font)
  end

  local visible, open = reaper.ImGui_Begin(ctx, "Auto region from items", true,
    reaper.ImGui_WindowFlags_AlwaysAutoResize())

  if not open then
    ui_open = false
    reaper.ImGui_End(ctx)
    return false
  end

  if visible then
    -- Ligne 1 : Global title + Numbering (mode projet)
    reaper.ImGui_Text(ctx, "Prefix")
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_SetNextItemWidth(ctx, 200)
    local rt, tv = reaper.ImGui_InputText(ctx, "##title", ui_title)
    if rt then ui_title = tv end

    reaper.ImGui_Text(ctx, "Item naming")
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_SetNextItemWidth(ctx, 120)
    local rm, nm = reaper.ImGui_Combo(ctx, "##mode", ui_mode,
      table.concat(MODE_LABELS, "\0") .. "\0")
    if rm then ui_mode = nm end

    -- Padding (si mode Numbering)
    if ui_mode == MODE_NUM then
      reaper.ImGui_SameLine(ctx)
      reaper.ImGui_SetNextItemWidth(ctx, 40)
      local rp, pv = reaper.ImGui_InputText(ctx, "##pad", ui_padding_str)
      if rp then ui_padding_str = pv end
    end

    reaper.ImGui_Text(ctx, "Separator")
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_SetNextItemWidth(ctx, 40)
    local rs, sv = reaper.ImGui_InputText(ctx, "##sep", ui_sep)
    if rs then ui_sep = sv end

    reaper.ImGui_Separator(ctx)

    if reaper.ImGui_Button(ctx, "Refresh tracks", 120, 0) then
      local saved_checks = {}
      local saved_cfg    = {}
      for guid, v in pairs(ui_checks) do saved_checks[guid] = v end
      for guid, v in pairs(ui_cfg)    do saved_cfg[guid]    = v end
      buildTrackList()
      for _, t in ipairs(ui_tracks) do
        if saved_checks[t.guid] == nil then
          ui_checks[t.guid] = false
          ui_cfg[t.guid] = { src = SRC_TRACK, custom = "" }
        else
          ui_checks[t.guid] = saved_checks[t.guid]
          ui_cfg[t.guid]    = saved_cfg[t.guid]
        end
      end
    end

    -- Hauteur dynamique : 28px par piste
    local child_h = math.min(#ui_tracks * 28, 500)

    reaper.ImGui_BeginChild(ctx, "tracklist", 560, child_h)

    for _, t in ipairs(ui_tracks) do
      local c = ui_cfg[t.guid]

      if t.depth > 0 then reaper.ImGui_Indent(ctx, t.depth * 12) end

      -- Couleur de piste
      local has_color = t.color ~= 0
      if has_color then
        local r = (t.color >> 16) & 0xFF
        local g = (t.color >> 8)  & 0xFF
        local b =  t.color        & 0xFF
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), (r << 24) | (g << 16) | (b << 8) | 0xFF)
      end

      local rv, checked = reaper.ImGui_Checkbox(ctx, t.name .. "##chk_" .. t.guid, ui_checks[t.guid])
      if rv then ui_checks[t.guid] = checked end

      if has_color then reaper.ImGui_PopStyleColor(ctx) end

      if ui_checks[t.guid] then
        -- Prompt custom inline : si vide → SRC_TRACK, sinon → SRC_CUSTOM
        reaper.ImGui_SameLine(ctx)
        reaper.ImGui_SetNextItemWidth(ctx, 160)
        local rc, cv = reaper.ImGui_InputText(ctx, "##cust_" .. t.guid, c.custom)
        if rc then
          c.custom = cv
          c.src = (cv and cv ~= "") and SRC_CUSTOM or SRC_TRACK
        end
      end

      if t.depth > 0 then reaper.ImGui_Unindent(ctx, t.depth * 12) end
    end

    reaper.ImGui_EndChild(ctx)
    reaper.ImGui_Separator(ctx)

    -- Collecte de l'état UI courant
    local function collectResult()
      local selected  = {}
      local new_cfg   = {}
      local padding   = tonumber(ui_padding_str) or 1
      if padding < 1 then padding = 1 end
      for _, t in ipairs(ui_tracks) do
        if ui_checks[t.guid] then
          selected[#selected + 1] = t.guid
          local c = ui_cfg[t.guid]
          new_cfg[t.guid] = {
            src    = c.src,
            custom = c.custom or "",
          }
        end
      end
      local sep = (ui_sep and ui_sep ~= "") and ui_sep or "_"
      return { guids = selected, cfg = new_cfg, title = ui_title, mode = ui_mode, padding = padding, sep = sep }
    end

    if reaper.ImGui_Button(ctx, "Apply & run in background", 170, 0) then
      ui_open = false
      reaper.ImGui_End(ctx)
      return collectResult()
    end

    reaper.ImGui_SameLine(ctx)

    if reaper.ImGui_Button(ctx, "Apply once", 80, 0) then
      ui_open = false
      reaper.ImGui_End(ctx)
      local r = collectResult()
      r.once = true
      return r
    end

    reaper.ImGui_SameLine(ctx)

    if reaper.ImGui_Button(ctx, "Cancel", 80, 0) then
      ui_open = false
      reaper.ImGui_End(ctx)
      return false
    end
  end

  reaper.ImGui_End(ctx)
  return "pending"
end

-- ─────────────────────────────────────────────
-- Toggle command state
-- ─────────────────────────────────────────────

local _, _, section_id, cmd_id = reaper.get_action_context()

local function setToggle(state)
  reaper.SetToggleCommandState(section_id, cmd_id, state)
  reaper.RefreshToolbar2(section_id, cmd_id)
end

-- ─────────────────────────────────────────────
-- État global
-- ─────────────────────────────────────────────

local watched_guids  = {}
local item_to_region = {}
local single_regions = {}
local track_cfg      = {}
local title          = ""
local proj_mode      = MODE_ITEM
local proj_padding   = 1
local proj_sep       = "_"
local prev_snapshot  = {}
local prev_single    = {}
local config_pending = false

-- ─────────────────────────────────────────────
-- Boucle principale
-- ─────────────────────────────────────────────

local function applyResult(result)
  if #result.guids == 0 then return false end
  watched_guids = result.guids
  track_cfg     = result.cfg
  title         = result.title or ""
  proj_mode     = result.mode or MODE_ITEM
  proj_padding  = result.padding or 1
  proj_sep      = result.sep or "_"

  local curr, curr_s = buildSnapshot(watched_guids, track_cfg, title, proj_mode, proj_padding, proj_sep)

  for guid, data in pairs(curr) do
    if item_to_region[guid] and not prev_snapshot[guid] then
      prev_snapshot[guid] = { pos = data.pos, len = data.len, name = "" }
    end
  end
  for guid in pairs(prev_snapshot) do
    if not curr[guid] then prev_snapshot[guid] = nil end
  end
  for guid in pairs(item_to_region) do
    if not curr[guid] then item_to_region[guid] = nil end
  end

  saveState(watched_guids, item_to_region, track_cfg, title, single_regions, proj_mode, proj_padding, proj_sep)
  prev_single = curr_s
  return true
end

local function deferLoop()
  if config_pending then
    local result = tickConfigUI()

    if result == "pending" then
      reaper.defer(deferLoop)
      return
    end

    config_pending = false
    if result == false then
      if #watched_guids == 0 then return end
    elseif type(result) == "table" then
      if not applyResult(result) then return end
      if result.once then
        local curr, curr_s = buildSnapshot(watched_guids, track_cfg, title, proj_mode, proj_padding, proj_sep)
        applyDiff(prev_snapshot, curr, item_to_region, prev_single, curr_s, single_regions)
        saveState(watched_guids, item_to_region, track_cfg, title, single_regions, proj_mode, proj_padding, proj_sep)
        reaper.UpdateArrange()
        return
      end
    end
  end

  local curr, curr_s = buildSnapshot(watched_guids, track_cfg, title, proj_mode, proj_padding, proj_sep)
  local changed = applyDiff(prev_snapshot, curr, item_to_region, prev_single, curr_s, single_regions)

  prev_snapshot = curr
  prev_single   = curr_s

  if changed then
    saveState(watched_guids, item_to_region, track_cfg, title, single_regions, proj_mode, proj_padding, proj_sep)
    reaper.UpdateArrange()
  end

  reaper.defer(deferLoop)
end

-- ─────────────────────────────────────────────
-- Point d'entrée
-- ─────────────────────────────────────────────

local function main()
  if not reaper.BR_GetMediaItemGUID then
    reaper.ShowMessageBox(
      "Ce script nécessite l'extension SWS.\nTéléchargeable sur https://www.sws-extension.org/",
      "AutoRegionFromItems", 0)
    return
  end

  if not reaper.ImGui_CreateContext then
    reaper.ShowMessageBox(
      "Ce script nécessite l'extension ReaImGui.\nInstallez-la via ReaPack.",
      "AutoRegionFromItems", 0)
    return
  end

  watched_guids, item_to_region, track_cfg, title, single_regions, proj_mode, proj_padding, proj_sep = loadState()
  openConfigUI(watched_guids, track_cfg, title, proj_mode, proj_padding, proj_sep)
  config_pending = true
  prev_snapshot  = {}
  prev_single    = {}

  setToggle(1)
  reaper.defer(deferLoop)
  reaper.atexit(function() setToggle(0) end)
end

main()
