-- @description Auto region from items: shared state and snapshot/diff logic
-- @author lepierrealain
-- @version 2.0

-- Shared by the background watcher and its settings window. Configuration is
-- stored in the current project. Each watched track owns its region mode and
-- naming template; mappings keep generated regions stable between passes.

local EXT_NS     = "AutoRegions"
local EXT_TRACKS = "tracks"
local EXT_MAP    = "map"
local EXT_TITLE  = "title"  -- legacy, kept for one-time migration
local EXT_CFG    = "cfg"
local EXT_MODE   = "mode"   -- legacy: mode|padding|separator
local EXT_GROUP  = "group"  -- legacy group name

local STAMP_NS = "PA_AutoRegions"

-- Persisted values. The first four retain their historical numeric values so
-- existing projects can be migrated without ambiguity.
PA_AR_MODE_ALL    = 0
PA_AR_MODE_NUM    = 1 -- legacy Numbering, migrated to ALL + $itemnumber
PA_AR_MODE_FIRST  = 2
PA_AR_MODE_GROUP  = 3
PA_AR_MODE_CLOSE  = 4

-- Backward-compatible aliases for scripts which may still use the old names.
PA_AR_MODE_ITEM   = PA_AR_MODE_ALL
PA_AR_MODE_SINGLE = PA_AR_MODE_FIRST

PA_AR_DEFAULT_GAP    = 1

function PA_AR_DefaultNaming(mode)
  if mode == PA_AR_MODE_ALL then return "$track_$item" end
  if mode == PA_AR_MODE_GROUP or mode == PA_AR_MODE_CLOSE then
    return "$track_$itemnumber"
  end
  return "$track"
end

PA_AR_DEFAULT_NAMING = PA_AR_DefaultNaming(PA_AR_MODE_FIRST)

local function split(str, sep)
  local result = {}
  for part in str:gmatch("[^" .. sep .. "]+") do
    result[#result + 1] = part
  end
  return result
end

local MEDIA_EXTS = {
  wav = true, aif = true, aiff = true, flac = true, mp3 = true, ogg = true,
  opus = true, m4a = true, aac = true, wv = true, ape = true, wma = true,
  mp4 = true, mov = true, mkv = true, avi = true, webm = true, m4v = true,
  midi = true, mid = true, rex = true, rx2 = true, w64 = true, caf = true,
}

local function stripMediaExt(name)
  local base, ext = name:match("^(.*)%.([%w]+)$")
  if base and base ~= "" and MEDIA_EXTS[ext:lower()] then return base end
  return name
end

local function itemName(item)
  local take = reaper.GetActiveTake(item)
  if take then return stripMediaExt(reaper.GetTakeName(take)) end
  return "Item"
end

local function trackName(track)
  local _, name = reaper.GetTrackName(track)
  return name or ""
end

local function projectName()
  local _, filename = reaper.EnumProjects(-1, "")
  if not filename or filename == "" then return "Untitled" end
  local name = filename:match("([^\\/]+)$") or filename
  return (name:gsub("%.[Rr][Pp][Pp]$", ""))
end

local function encodeText(s)
  return ((s or ""):gsub("[%%;|]", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

local function decodeText(s)
  return ((s or ""):gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end

function PA_AR_CopyConfig(cfg)
  return {
    mode     = cfg.mode,
    naming   = cfg.naming,
    children = cfg.children == true,
    gap      = cfg.gap,
  }
end

function PA_AR_DefaultConfig()
  local mode = PA_AR_MODE_FIRST
  return {
    mode     = mode,
    naming   = PA_AR_DefaultNaming(mode),
    children = false,
    gap      = PA_AR_DEFAULT_GAP,
  }
end

-- New entry format:
--   track_guid|mode|include_children|close_gap|percent_encoded_naming
-- The track list remains separate to preserve its project order.
local function encodeCfg(track_cfg, guids)
  local parts = {}
  for _, tguid in ipairs(guids or {}) do
    local cfg = track_cfg[tguid]
    if cfg then
      parts[#parts + 1] = table.concat({
        tguid,
        tostring(cfg.mode or PA_AR_MODE_FIRST),
        cfg.children and "1" or "0",
        string.format("%.9g", tonumber(cfg.gap) or PA_AR_DEFAULT_GAP),
        encodeText(cfg.naming or PA_AR_DefaultNaming(cfg.mode)),
      }, "|")
    end
  end
  return table.concat(parts, ";")
end

local function decodeCfg(str)
  local cfg = {}
  if not str or str == "" then return cfg, false end
  local has_new_format = false
  for _, entry in ipairs(split(str, ";")) do
    local tguid, mode, children, gap, naming =
      entry:match("^([^|]+)|(%d+)|([01])|([^|]*)|(.*)$")
    if tguid then
      has_new_format = true
      local m = tonumber(mode) or PA_AR_MODE_FIRST
      if m ~= PA_AR_MODE_FIRST and m ~= PA_AR_MODE_ALL
        and m ~= PA_AR_MODE_GROUP and m ~= PA_AR_MODE_CLOSE then
        m = PA_AR_MODE_FIRST
      end
      cfg[tguid] = {
        mode     = m,
        children = children == "1",
        gap      = math.max(0, tonumber(gap) or PA_AR_DEFAULT_GAP),
        naming   = decodeText(naming),
      }
    else
      -- Legacy entry: track_guid or track_guid|custom_track_name.
      local old_guid, old_name = entry:match("^([^|]+)|(.*)$")
      if not old_guid then old_guid, old_name = entry, "" end
      if old_guid then
        cfg[old_guid] = { legacy_name = old_name ~= "" and decodeText(old_name) or nil }
      end
    end
  end
  return cfg, has_new_format
end

local function liveRegionIndexes()
  local live = {}
  local i = 0
  while true do
    local retval, isrgn, _, _, _, markrgnindex = reaper.EnumProjectMarkers(i)
    if retval == 0 then break end
    if isrgn then live[markrgnindex] = true end
    i = i + 1
  end
  return live
end

function PA_AR_SaveState(state)
  reaper.SetProjExtState(0, EXT_NS, EXT_TRACKS, table.concat(state.guids, "|"))
  reaper.SetProjExtState(0, EXT_NS, EXT_CFG, encodeCfg(state.cfg, state.guids))

  local parts = {}
  for key, idx in pairs(state.map) do
    parts[#parts + 1] = key .. ":" .. tostring(idx)
  end
  for tguid, idx in pairs(state.single) do
    if reaper.BR_GetMediaTrackByGUID(0, tguid) then
      parts[#parts + 1] = "T:" .. tguid .. ":" .. tostring(idx)
    end
  end
  reaper.SetProjExtState(0, EXT_NS, EXT_MAP, table.concat(parts, "|"))
end

local function joinLegacy(parts, sep)
  local result = {}
  for _, value in ipairs(parts) do
    if value and value ~= "" then result[#result + 1] = value end
  end
  return table.concat(result, (sep and sep ~= "") and sep or "_")
end

function PA_AR_LoadState()
  local state = { guids = {}, map = {}, single = {}, cfg = {} }

  local _, tracks_str = reaper.GetProjExtState(0, EXT_NS, EXT_TRACKS)
  if tracks_str and tracks_str ~= "" then state.guids = split(tracks_str, "|") end

  local live = liveRegionIndexes()
  local _, map_str = reaper.GetProjExtState(0, EXT_NS, EXT_MAP)
  if map_str and map_str ~= "" then
    for _, pair in ipairs(split(map_str, "|")) do
      if pair:sub(1, 2) == "T:" then
        local tguid, idx = pair:sub(3):match("^(.+):(%d+)$")
        idx = tonumber(idx)
        if tguid and idx and live[idx] then state.single[tguid] = idx end
      else
        local key, idx = pair:match("^(.+):(%d+)$")
        idx = tonumber(idx)
        if key and idx and live[idx] then state.map[key] = idx end
      end
    end
  end

  local _, cfg_str = reaper.GetProjExtState(0, EXT_NS, EXT_CFG)
  local decoded, is_new = decodeCfg(cfg_str)

  if is_new then
    state.cfg = decoded
  else
    -- Migrate the old project-wide mode/naming controls into one config per
    -- watched track. Saving after the next pass writes only the new format.
    local _, title = reaper.GetProjExtState(0, EXT_NS, EXT_TITLE)
    local _, group_name = reaper.GetProjExtState(0, EXT_NS, EXT_GROUP)
    local _, mode_str = reaper.GetProjExtState(0, EXT_NS, EXT_MODE)
    local old_mode, old_sep = PA_AR_MODE_FIRST, "_"
    if mode_str and mode_str ~= "" then
      local m, _, s = mode_str:match("^(%d+)|(%d+)|(.*)$")
      old_mode = tonumber(m) or PA_AR_MODE_FIRST
      old_sep = (s and s ~= "") and s or "_"
    end

    for _, tguid in ipairs(state.guids) do
      local old = decoded[tguid] or {}
      local middle = old.legacy_name or "$track"
      local cfg = PA_AR_DefaultConfig()
      if old_mode == PA_AR_MODE_ITEM then
        cfg.mode = PA_AR_MODE_ALL
        cfg.naming = joinLegacy({ title, middle, "$item" }, old_sep)
      elseif old_mode == PA_AR_MODE_NUM then
        cfg.mode = PA_AR_MODE_ALL
        cfg.naming = joinLegacy({ title, middle, "$itemnumber" }, old_sep)
      elseif old_mode == PA_AR_MODE_GROUP then
        cfg.mode = PA_AR_MODE_GROUP
        cfg.naming = joinLegacy({ title, group_name, "$itemnumber" }, old_sep)
      else
        cfg.mode = PA_AR_MODE_FIRST
        cfg.naming = joinLegacy({ title, middle }, old_sep)
      end
      state.cfg[tguid] = cfg
    end
  end

  -- A missing/corrupt config should never make a checked track disappear.
  for _, tguid in ipairs(state.guids) do
    if not state.cfg[tguid] then state.cfg[tguid] = PA_AR_DefaultConfig() end
  end

  return state
end

function PA_AR_TouchStamp()
  reaper.SetExtState(STAMP_NS, "stamp", tostring(reaper.time_precise()), false)
end

function PA_AR_Stamp()
  return reaper.GetExtState(STAMP_NS, "stamp")
end

local function collectTrackItems(track, include_children)
  local tracks = { track }
  if include_children then
    local root_depth = reaper.GetTrackDepth(track)
    local root_index = math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")) - 1
    local count = reaper.CountTracks(0)
    for i = root_index + 1, count - 1 do
      local child = reaper.GetTrack(0, i)
      if reaper.GetTrackDepth(child) <= root_depth then break end
      tracks[#tracks + 1] = child
    end
  end

  local items = {}
  for _, source_track in ipairs(tracks) do
    for i = 0, reaper.GetTrackNumMediaItems(source_track) - 1 do
      local item = reaper.GetTrackMediaItem(source_track, i)
      items[#items + 1] = {
        order = #items + 1,
        guid  = reaper.BR_GetMediaItemGUID(item),
        pos   = reaper.GetMediaItemInfo_Value(item, "D_POSITION"),
        len   = reaper.GetMediaItemInfo_Value(item, "D_LENGTH"),
        name  = itemName(item),
        group = math.floor(reaper.GetMediaItemInfo_Value(item, "I_GROUPID") + 0.5),
      }
    end
  end
  table.sort(items, function(a, b)
    if a.pos ~= b.pos then return a.pos < b.pos end
    return a.order < b.order
  end)
  return items
end

local function expandNaming(template, values)
  template = (template and template ~= "") and template or PA_AR_DEFAULT_NAMING
  return (template:gsub("%$([%a]+)(0*)", function(token, zeros)
    local value = values[token]
    if value == nil then return "$" .. token .. zeros end
    if zeros ~= "" and (token == "itemnumber" or token == "tracknumber") then
      return string.format("%0" .. #zeros .. "d", tonumber(value) or 0)
    end
    return tostring(value) .. zeros
  end))
end

local function regionName(cfg, root_track, first_item, item_number, project_name)
  local track_number = math.floor(reaper.GetMediaTrackInfo_Value(root_track, "IP_TRACKNUMBER"))
  local naming = (cfg.naming and cfg.naming ~= "") and cfg.naming or PA_AR_DefaultNaming(cfg.mode)
  return expandNaming(naming, {
    project     = project_name,
    track       = trackName(root_track),
    tracknumber = track_number,
    item        = first_item and first_item.name or "",
    itemnumber  = item_number,
  })
end

function PA_AR_BuildSnapshot(state)
  local snapshot, first_snapshot = {}, {}
  local project_name = projectName()

  for _, tguid in ipairs(state.guids) do
    local track = reaper.BR_GetMediaTrackByGUID(0, tguid)
    local cfg = state.cfg[tguid]
    if track and cfg then
      local grouped_mode = cfg.mode == PA_AR_MODE_GROUP or cfg.mode == PA_AR_MODE_CLOSE
      local items = collectTrackItems(track, grouped_mode and cfg.children)

      if cfg.mode == PA_AR_MODE_FIRST then
        local item = items[1]
        if item then
          first_snapshot[tguid] = {
            pos = item.pos, len = item.len,
            name = regionName(cfg, track, item, 1, project_name),
          }
        end

      elseif cfg.mode == PA_AR_MODE_ALL then
        for index, item in ipairs(items) do
          local key = "I:" .. tguid .. ":" .. item.guid
          snapshot[key] = {
            pos = item.pos, len = item.len,
            name = regionName(cfg, track, item, index, project_name),
          }
        end

      elseif cfg.mode == PA_AR_MODE_GROUP then
        local groups = {}
        for _, item in ipairs(items) do
          if item.group ~= 0 then
            local group = groups[item.group]
            local item_end = item.pos + item.len
            if not group then
              groups[item.group] = {
                id = item.group, pos = item.pos, finish = item_end, first = item,
              }
            else
              if item.pos < group.pos then group.pos, group.first = item.pos, item end
              if item_end > group.finish then group.finish = item_end end
            end
          end
        end
        local ordered = {}
        for _, group in pairs(groups) do ordered[#ordered + 1] = group end
        table.sort(ordered, function(a, b)
          if a.pos ~= b.pos then return a.pos < b.pos end
          return a.id < b.id
        end)
        for index, group in ipairs(ordered) do
          local key = "G:" .. tguid .. ":" .. tostring(group.id)
          snapshot[key] = {
            pos = group.pos, len = group.finish - group.pos,
            name = regionName(cfg, track, group.first, index, project_name),
          }
        end

      elseif cfg.mode == PA_AR_MODE_CLOSE then
        local close_groups = {}
        local max_gap = math.max(0, tonumber(cfg.gap) or PA_AR_DEFAULT_GAP)
        for _, item in ipairs(items) do
          local item_end = item.pos + item.len
          local group = close_groups[#close_groups]
          if not group or item.pos - group.finish >= max_gap then
            close_groups[#close_groups + 1] = {
              pos = item.pos, finish = item_end, first = item,
            }
          elseif item_end > group.finish then
            group.finish = item_end
          end
        end
        for index, group in ipairs(close_groups) do
          local key = "C:" .. tguid .. ":" .. group.first.guid
          snapshot[key] = {
            pos = group.pos, len = group.finish - group.pos,
            name = regionName(cfg, track, group.first, index, project_name),
          }
        end
      end
    end
  end

  return snapshot, first_snapshot
end

-- Keep REAPER's displayed region IDs (the number shown at the left of each
-- region) in timeline order. All regions are moved to temporary IDs first so
-- assigning 1..N cannot collide with an ID which has not been changed yet.
local function renumberProjectRegions(state)
  local regions = {}
  local enum_index = 0
  local max_id = 0

  while true do
    local retval, is_region, pos, region_end, name, id, color =
      reaper.EnumProjectMarkers3(0, enum_index)
    if retval == 0 then break end
    if is_region then
      regions[#regions + 1] = {
        enum_index = enum_index,
        pos = pos,
        region_end = region_end,
        name = name,
        id = id,
        color = color,
      }
      if id > max_id then max_id = id end
    end
    enum_index = enum_index + 1
  end

  table.sort(regions, function(a, b)
    if a.pos ~= b.pos then return a.pos < b.pos end
    if a.region_end ~= b.region_end then return a.region_end < b.region_end end
    return a.enum_index < b.enum_index
  end)

  local needs_update = false
  for index, region in ipairs(regions) do
    if region.id ~= index then
      needs_update = true
      break
    end
  end
  if not needs_update then return false end

  local temporary_base = max_id + #regions + 1
  for index, region in ipairs(regions) do
    reaper.SetProjectMarkerByIndex2(0, region.enum_index, true,
      region.pos, region.region_end, temporary_base + index,
      region.name, region.color, 2)
  end

  local remapped_ids = {}
  for index, region in ipairs(regions) do
    reaper.SetProjectMarkerByIndex2(0, region.enum_index, true,
      region.pos, region.region_end, index, region.name, region.color, 2)
    remapped_ids[region.id] = index
  end
  reaper.SetProjectMarkerByIndex2(0, -1, false, 0, 0, -1, "", 0, 2)

  for key, id in pairs(state.map) do
    if remapped_ids[id] then state.map[key] = remapped_ids[id] end
  end
  for tguid, id in pairs(state.single) do
    if remapped_ids[id] then state.single[tguid] = remapped_ids[id] end
  end

  return true
end

function PA_AR_ApplyDiff(prev, curr, prev_first, curr_first, state)
  local dirty = false

  for key in pairs(prev) do
    if not curr[key] then
      local idx = state.map[key]
      if idx then
        reaper.DeleteProjectMarker(0, idx, true)
        state.map[key] = nil
        dirty = true
      end
    end
  end
  for key, data in pairs(curr) do
    if not prev[key] then
      local idx = state.map[key]
      if idx then
        reaper.SetProjectMarker4(0, idx, true, data.pos, data.pos + data.len, data.name, 0, 0)
      else
        state.map[key] = reaper.AddProjectMarker2(0, true, data.pos, data.pos + data.len, data.name, -1, 0)
      end
      dirty = true
    end
  end
  for key, data in pairs(curr) do
    local old = prev[key]
    if old and (old.pos ~= data.pos or old.len ~= data.len or old.name ~= data.name) then
      local idx = state.map[key]
      if idx then
        reaper.SetProjectMarker4(0, idx, true, data.pos, data.pos + data.len, data.name, 0, 0)
        dirty = true
      end
    end
  end

  -- First item retains the former single-mode behavior: once created, its
  -- region is not deleted merely because the track temporarily has no item.
  for tguid, data in pairs(curr_first) do
    local idx = state.single[tguid]
    if not idx then
      idx = reaper.AddProjectMarker2(0, true, data.pos, data.pos + data.len, data.name, -1, 0)
      state.single[tguid] = idx
      dirty = true
    else
      local old = prev_first[tguid]
      if not old or old.pos ~= data.pos or old.len ~= data.len or old.name ~= data.name then
        reaper.SetProjectMarker4(0, idx, true, data.pos, data.pos + data.len, data.name, 0, 0)
        dirty = true
      end
    end
  end

  if #state.guids > 0 then
    dirty = renumberProjectRegions(state) or dirty
  end

  return dirty
end

function PA_AR_ValidateMappings(state, prev_snapshot)
  local live = liveRegionIndexes()
  for key, idx in pairs(state.map) do
    if not live[idx] then
      state.map[key] = nil
      if prev_snapshot then prev_snapshot[key] = nil end
    end
  end
  for tguid, idx in pairs(state.single) do
    if not live[idx] then state.single[tguid] = nil end
  end
end

function PA_AR_Resync(state)
  PA_AR_ValidateMappings(state)
  local curr, curr_first = PA_AR_BuildSnapshot(state)
  local dirty = false

  for key, idx in pairs(state.map) do
    if not curr[key] then
      reaper.DeleteProjectMarker(0, idx, true)
      state.map[key] = nil
      dirty = true
    end
  end
  for tguid, idx in pairs(state.single) do
    local cfg = state.cfg[tguid]
    if not cfg or cfg.mode ~= PA_AR_MODE_FIRST then
      reaper.DeleteProjectMarker(0, idx, true)
      state.single[tguid] = nil
      dirty = true
    end
  end

  dirty = PA_AR_ApplyDiff({}, curr, {}, curr_first, state) or dirty
  PA_AR_SaveState(state)
  if dirty then reaper.UpdateArrange() end
  return curr, curr_first
end
