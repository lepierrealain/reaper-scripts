-- @description Auto region from items: état partagé + logique snapshot/diff
-- @author lepierrealain
-- @version 1.1

-- Librairie partagée entre "PA_Auto region from items" (watcher defer) et sa
-- fenêtre de réglages. L'état vit dans le ProjExtState "AutoRegions" du projet
-- (pistes suivies, mapping item→région, nommage) ; un horodatage non persisté
-- dans reaper-extstate.ini (section PA_AutoRegions) réveille le watcher quand
-- les réglages changent.

local EXT_NS     = "AutoRegions"
local EXT_TRACKS = "tracks"
local EXT_MAP    = "map"
local EXT_TITLE  = "title"
local EXT_CFG    = "cfg"     -- par piste : tguid[|nom_custom]  (mode/padding/sep → niveau projet)
local EXT_MODE   = "mode"    -- projet : mode|padding|sep
local EXT_GROUP  = "group"   -- projet : nom de base du mode Item group

local STAMP_NS   = "PA_AutoRegions"  -- ext state global (stamp non persisté)

-- mode : 0=Item name  1=Numbering  2=Single  3=Item group
-- (valeurs figées : elles sont persistées en ExtState ; l'ordre d'affichage
--  du combo des réglages est géré séparément côté fenêtre)
PA_AR_MODE_ITEM   = 0
PA_AR_MODE_NUM    = 1
PA_AR_MODE_SINGLE = 2
PA_AR_MODE_GROUP  = 3

-- ─── Utilitaires ────────────────────────────────────────────────────────

local function split(str, sep)
  local result = {}
  for part in str:gmatch("[^" .. sep .. "]+") do
    result[#result + 1] = part
  end
  return result
end

-- Extensions média connues : retirées du nom d'item (beaucoup d'items
-- s'appellent "prise.wav" ou "clip.mp4"). On ne touche qu'à ces extensions
-- pour ne jamais tronquer un nom qui contient un point sans être un fichier.
local MEDIA_EXTS = {
  wav = true, aif = true, aiff = true, flac = true, mp3 = true, ogg = true,
  opus = true, m4a = true, aac = true, wv = true, ape = true, wma = true,
  mp4 = true, mov = true, mkv = true, avi = true, webm = true, m4v = true,
  midi = true, mid = true, rex = true, rx2 = true, w64 = true, caf = true,
}

local function stripMediaExt(name)
  local base, ext = name:match("^(.*)%.([%w]+)$")
  if base and base ~= "" and MEDIA_EXTS[ext:lower()] then
    return base
  end
  return name
end

local function itemName(item)
  local take = reaper.GetActiveTake(item)
  if take then return stripMediaExt(reaper.GetTakeName(take)) end
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

-- ─── Persistance ────────────────────────────────────────────────────────

-- Le nom custom peut contenir les séparateurs d'encodage (";" et "|") :
-- on les percent-encode pour que le décodage reste sans ambiguïté.
local function encodeName(s)
  return (s:gsub("[%%;|]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function decodeName(s)
  return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

-- Encodage par piste : tguid ou tguid|nom_custom  (mode et padding sont au niveau projet)
local function encodeCfg(track_cfg)
  local parts = {}
  for tguid, cfg in pairs(track_cfg) do
    if cfg.name then
      parts[#parts + 1] = tguid .. "|" .. encodeName(cfg.name)
    else
      parts[#parts + 1] = tguid
    end
  end
  return table.concat(parts, ";")
end

local function decodeCfg(str)
  local cfg = {}
  if not str or str == "" then return cfg end
  for _, entry in ipairs(split(str, ";")) do
    local tguid, enc = entry:match("^([^|]+)|([^|]*)$")
    if tguid then
      cfg[tguid] = { name = decodeName(enc) }
    else
      -- Entrée sans nom custom, ou anciennes données (tguid|src|custom) :
      -- on ne garde que le tguid
      tguid = entry:match("^([^|]+)")
      if tguid then cfg[tguid] = {} end
    end
  end
  return cfg
end

-- Ensemble des index (display number) de régions réellement présentes dans le projet
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

-- État complet : guids (pistes suivies, liste ordonnée), cfg (tguid → {name}),
-- title, mode, padding, sep, map (iguid → region_idx), single (tguid → region_idx).
function PA_AR_SaveState(state)
  reaper.SetProjExtState(0, EXT_NS, EXT_TITLE,  state.title or "")
  reaper.SetProjExtState(0, EXT_NS, EXT_TRACKS, table.concat(state.guids, "|"))
  reaper.SetProjExtState(0, EXT_NS, EXT_CFG,    encodeCfg(state.cfg))
  reaper.SetProjExtState(0, EXT_NS, EXT_MODE,
    tostring(state.mode or PA_AR_MODE_SINGLE) .. "|" .. tostring(state.padding or 1) .. "|" .. (state.sep or "_"))
  reaper.SetProjExtState(0, EXT_NS, EXT_GROUP, state.group or "")

  -- MAP : iguid:ridx pour les modes normaux ; tguid:ridx pour single mode (préfixe "T:")
  local parts = {}
  for guid, idx in pairs(state.map) do
    parts[#parts + 1] = guid .. ":" .. tostring(idx)
  end
  for tguid, idx in pairs(state.single) do
    -- Ne pas persister les pistes qui n'existent plus dans le projet
    if reaper.BR_GetMediaTrackByGUID(0, tguid) then
      parts[#parts + 1] = "T:" .. tguid .. ":" .. tostring(idx)
    end
  end
  reaper.SetProjExtState(0, EXT_NS, EXT_MAP, table.concat(parts, "|"))
end

function PA_AR_LoadState()
  local state = {
    guids   = {},
    map     = {},   -- iguid → region_idx (modes Item name + Numbering)
    single  = {},   -- tguid → region_idx (single mode)
    cfg     = {},
    title   = "",
    mode    = PA_AR_MODE_SINGLE,
    padding = 1,
    sep     = "_",
    group   = "",   -- nom de base du mode Item group
  }

  local _, tracks_str = reaper.GetProjExtState(0, EXT_NS, EXT_TRACKS)
  if tracks_str and tracks_str ~= "" then state.guids = split(tracks_str, "|") end

  -- On ne réutilise un index sauvegardé que si la région existe encore.
  -- Sinon (région supprimée manuellement depuis la dernière session), on l'oublie
  -- pour que le diff suivant la recrée.
  local live = liveRegionIndexes()

  local _, map_str = reaper.GetProjExtState(0, EXT_NS, EXT_MAP)
  if map_str and map_str ~= "" then
    for _, pair in ipairs(split(map_str, "|")) do
      if pair:sub(1, 2) == "T:" then
        local tguid, idx = pair:sub(3):match("^(.+):(%d+)$")
        idx = tonumber(idx)
        if tguid and idx and live[idx] then state.single[tguid] = idx end
      else
        local guid, idx = pair:match("^(.+):(%d+)$")
        idx = tonumber(idx)
        if guid and idx and live[idx] then state.map[guid] = idx end
      end
    end
  end

  local _, cfg_str = reaper.GetProjExtState(0, EXT_NS, EXT_CFG)
  state.cfg = decodeCfg(cfg_str)

  local _, t = reaper.GetProjExtState(0, EXT_NS, EXT_TITLE)
  if t and t ~= "" then state.title = t end

  local _, g = reaper.GetProjExtState(0, EXT_NS, EXT_GROUP)
  if g and g ~= "" then state.group = g end

  local _, mode_str = reaper.GetProjExtState(0, EXT_NS, EXT_MODE)
  if mode_str and mode_str ~= "" then
    local m, p, s = mode_str:match("^(%d+)|(%d+)|(.*)$")
    if m then
      state.mode    = tonumber(m) or PA_AR_MODE_SINGLE
      state.padding = tonumber(p) or 1
      state.sep     = (s and s ~= "") and s or "_"
    end
  end

  return state
end

-- Horodatage non persisté : posé par la fenêtre de réglages après sauvegarde,
-- lu par le watcher pour recharger l'état du projet.
function PA_AR_TouchStamp()
  reaper.SetExtState(STAMP_NS, "stamp", tostring(reaper.time_precise()), false)
end

function PA_AR_Stamp()
  return reaper.GetExtState(STAMP_NS, "stamp")
end

-- ─── Snapshot ───────────────────────────────────────────────────────────

-- Retourne deux tables :
--   snapshot      iguid → { pos, len, name }   pour modes Item name + Numbering
--   single_snap   tguid → { pos, len, name }   pour Single mode
function PA_AR_BuildSnapshot(state)
  local watched_set = {}
  for _, g in ipairs(state.guids) do watched_set[g] = true end

  local snapshot    = {}
  local single_snap = {}
  local has_title   = state.title and state.title ~= ""
  local sep         = (state.sep and state.sep ~= "") and state.sep or "_"

  -- Mode Item group : le regroupement est GLOBAL (tous les items de toutes
  -- les pistes surveillées partageant le même group ID REAPER forment un seul
  -- groupe → une seule région). On accumule ici pendant la boucle par piste,
  -- puis on construit les régions une fois après la boucle.
  local groups = {}   -- gid → { gid, min_pos, max_end }

  local num_tracks = reaper.CountTracks(0)
  for t = 0, num_tracks - 1 do
    local track = reaper.GetTrack(0, t)
    local tguid = reaper.GetTrackGUID(track)
    if not watched_set[tguid] then goto continue end

    local cfg = state.cfg[tguid]
    if not cfg then goto continue end

    local items = {}
    for i = 0, reaper.GetTrackNumMediaItems(track) - 1 do
      local item = reaper.GetTrackMediaItem(track, i)
      items[#items + 1] = {
        guid  = reaper.BR_GetMediaItemGUID(item),
        pos   = reaper.GetMediaItemInfo_Value(item, "D_POSITION"),
        len   = reaper.GetMediaItemInfo_Value(item, "D_LENGTH"),
        name  = itemName(item),
        group = reaper.GetMediaItemInfo_Value(item, "I_GROUPID"),
      }
    end

    -- Nom custom éventuel (cfg.name) ; vide → composant omis, donc pas de
    -- séparateur après le prefix. Absent → suit le nom de la piste.
    local middle = cfg.name or trackName(track)
    if middle == "" then middle = nil end

    local function make_name(suffix)
      local p = {}
      if has_title then p[#p + 1] = state.title end
      if middle    then p[#p + 1] = middle end
      if suffix    then p[#p + 1] = suffix end
      return table.concat(p, sep)
    end

    if state.mode == PA_AR_MODE_ITEM then
      for _, item in ipairs(items) do
        snapshot[item.guid] = { pos = item.pos, len = item.len, name = make_name(item.name) }
      end

    elseif state.mode == PA_AR_MODE_NUM then
      local count   = #items
      local padding = state.padding or 1
      local needed  = #tostring(count)
      if needed > padding then padding = needed end
      for idx, item in ipairs(items) do
        snapshot[item.guid] = { pos = item.pos, len = item.len, name = make_name(formatNum(idx, padding)) }
      end

    elseif state.mode == PA_AR_MODE_SINGLE then
      if #items > 0 then
        local first = items[1]
        single_snap[tguid] = { pos = first.pos, len = first.len, name = make_name(nil) }
      end

    elseif state.mode == PA_AR_MODE_GROUP then
      -- Accumule les items groupés (I_GROUPID ≠ 0) de cette piste dans le
      -- regroupement global ; les items non groupés sont ignorés. La
      -- construction des régions a lieu après la boucle (voir plus bas).
      for _, item in ipairs(items) do
        local gid = math.floor((item.group or 0) + 0.5)  -- I_GROUPID peut être un float
        if gid ~= 0 then
          local g = groups[gid]
          local item_end = item.pos + item.len
          if not g then
            groups[gid] = { gid = gid, min_pos = item.pos, max_end = item_end }
          else
            if item.pos  < g.min_pos then g.min_pos = item.pos end
            if item_end  > g.max_end then g.max_end = item_end end
          end
        end
      end
    end

    ::continue::
  end

  -- Mode Item group : chaque group ID (fusionné sur toutes les pistes) donne
  -- une région du 1er au dernier item, numérotée par ordre chronologique
  -- (position du début du groupe). Le composant "nom" est le nom de base
  -- dédié (state.group).
  if state.mode == PA_AR_MODE_GROUP then
    local ordered = {}
    for _, g in pairs(groups) do ordered[#ordered + 1] = g end
    table.sort(ordered, function(a, b)
      if a.min_pos ~= b.min_pos then return a.min_pos < b.min_pos end
      return a.gid < b.gid
    end)

    local group_name = (state.group and state.group ~= "") and state.group or nil

    local count   = #ordered
    local padding = state.padding or 1
    local needed  = #tostring(count)
    if needed > padding then padding = needed end

    for idx, g in ipairs(ordered) do
      -- Clé synthétique stable, indépendante des items : la région suit le
      -- group ID global. Préfixe "G:" (distinct de "T:" du single mode).
      local key = "G:" .. tostring(g.gid)
      local p = {}
      if has_title  then p[#p + 1] = state.title end
      if group_name then p[#p + 1] = group_name end
      p[#p + 1] = formatNum(idx, padding)
      snapshot[key] = {
        pos  = g.min_pos,
        len  = g.max_end - g.min_pos,
        name = table.concat(p, sep),
      }
    end
  end

  return snapshot, single_snap
end

-- ─── Diff ───────────────────────────────────────────────────────────────

-- Applique les différences entre deux snapshots ; met à jour state.map /
-- state.single. Retourne true si quelque chose a changé dans le projet.
function PA_AR_ApplyDiff(prev, curr, prev_single, curr_single, state)
  local dirty = false

  -- Modes normaux (Item name + Numbering) : supprimer/créer/modifier
  for guid in pairs(prev) do
    if not curr[guid] then
      local idx = state.map[guid]
      if idx then
        reaper.DeleteProjectMarker(0, idx, true)
        state.map[guid] = nil
        dirty = true
      end
    end
  end
  for guid, data in pairs(curr) do
    if not prev[guid] then
      local idx = state.map[guid]
      if idx then
        -- Mapping hérité d'une session précédente (prev vide au démarrage) :
        -- réutiliser la région existante au lieu d'en créer un doublon.
        reaper.SetProjectMarker4(0, idx, true, data.pos, data.pos + data.len, data.name, 0, 0)
      else
        state.map[guid] = reaper.AddProjectMarker2(0, true, data.pos, data.pos + data.len, data.name, -1, 0)
      end
      dirty = true
    end
  end
  for guid, data in pairs(curr) do
    if prev[guid] then
      local p = prev[guid]
      if p.pos ~= data.pos or p.len ~= data.len or p.name ~= data.name then
        local idx = state.map[guid]
        if idx then
          reaper.SetProjectMarker4(0, idx, true, data.pos, data.pos + data.len, data.name, 0, 0)
          dirty = true
        end
      end
    end
  end

  -- Single mode : créer si absent, déplacer/renommer si présent, ne jamais supprimer
  for tguid, data in pairs(curr_single) do
    local idx = state.single[tguid]
    if not idx then
      idx = reaper.AddProjectMarker2(0, true, data.pos, data.pos + data.len, data.name, -1, 0)
      state.single[tguid] = idx
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

-- Oublie les mappings dont la région n'existe plus (suppression manuelle,
-- undo…) pour que le diff suivant la recrée au lieu d'appeler
-- SetProjectMarker4 sur un index mort (échec silencieux).
function PA_AR_ValidateMappings(state, prev_snapshot)
  local live = liveRegionIndexes()
  for guid, idx in pairs(state.map) do
    if not live[idx] then
      state.map[guid] = nil
      if prev_snapshot then prev_snapshot[guid] = nil end
    end
  end
  for tguid, idx in pairs(state.single) do
    if not live[idx] then state.single[tguid] = nil end
  end
end

-- ─── Resynchronisation complète ─────────────────────────────────────────

-- Passe complète depuis zéro : validation des mappings, suppression des
-- régions qui ne sont plus couvertes par la config (piste décochée,
-- changement de mode), puis diff depuis un état vide — les régions déjà
-- mappées sont mises à jour en place, les manquantes créées. Sauvegarde et
-- retourne (curr, curr_single) pour amorcer les diffs suivants du watcher.
function PA_AR_Resync(state)
  PA_AR_ValidateMappings(state)
  local curr, curr_s = PA_AR_BuildSnapshot(state)

  local watched_set = {}
  for _, g in ipairs(state.guids) do watched_set[g] = true end

  local dirty = false
  for guid, idx in pairs(state.map) do
    if not curr[guid] then
      reaper.DeleteProjectMarker(0, idx, true)
      state.map[guid] = nil
      dirty = true
    end
  end
  for tguid, idx in pairs(state.single) do
    if state.mode ~= PA_AR_MODE_SINGLE or not watched_set[tguid] then
      reaper.DeleteProjectMarker(0, idx, true)
      state.single[tguid] = nil
      dirty = true
    end
  end

  dirty = PA_AR_ApplyDiff({}, curr, {}, curr_s, state) or dirty
  PA_AR_SaveState(state)
  if dirty then reaper.UpdateArrange() end

  return curr, curr_s
end
