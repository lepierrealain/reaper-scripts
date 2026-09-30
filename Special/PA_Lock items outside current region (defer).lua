-- @description Lock items outside the region under the edit cursor (defer)
-- @author lepierrealain
-- @version 1.2
-- @about
--   Script toggle à laisser tourner en fond (toolbar ou __startup.lua).
--   Déverrouille les items qui chevauchent la région sous le curseur ainsi que
--   toute leur chaîne de voisins contigus sur la même piste. Entre deux régions,
--   conserve accessibles les régions voisines de gauche et de droite.
--   Les états de verrouillage d'origine sont restaurés à l'arrêt.

local r = reaper

local EPSILON = 1e-9

local _, _, section_id, command_id = r.get_action_context()

-- Relancer l'action termine l'instance précédente au lieu d'afficher le dialogue
-- "script already running" (API disponible à partir de REAPER 7.03).
if r.set_action_options then r.set_action_options(1) end

r.SetToggleCommandState(section_id, command_id, 1)
r.RefreshToolbar2(section_id, command_id)

local current_project = r.EnumProjects(-1)
local original_locks = {}
local active_regions = {}
local last_cursor_position = nil
local last_project_change = nil

local function item_key(item)
  local ok, guid = r.GetSetMediaItemInfo_String(item, "GUID", "", false)
  return ok and guid or tostring(item)
end

local function remember_item(item)
  local key = item_key(item)

  if original_locks[key] == nil then
    original_locks[key] = {
      item = item,
      locked = r.GetMediaItemInfo_Value(item, "C_LOCK")
    }
  else
    original_locks[key].item = item
  end

  return original_locks[key].locked
end

-- Renvoie la région sous le curseur. Dans un espace vide, renvoie plutôt les
-- régions immédiatement à gauche et à droite, si elles existent toutes les deux.
local function get_active_regions(project, position)
  local target = nil
  local left = nil
  local right = nil
  local entry_count = r.CountProjectMarkers(project)

  for i = 0, entry_count - 1 do
    local ok, is_region, region_start, region_end, _, region_id =
      r.EnumProjectMarkers3(project, i)

    if ok ~= 0 and is_region then
      local region = {
        id = region_id,
        start_pos = region_start,
        end_pos = region_end
      }

      if position >= region_start and position < region_end
          and (not target
            or region_start > target.start_pos
            or (region_start == target.start_pos and region_end < target.end_pos)) then
        target = region
      elseif region_end <= position
          and (not left
            or region_end > left.end_pos
            or (region_end == left.end_pos and region_start > left.start_pos)) then
        left = region
      elseif region_start > position
          and (not right
            or region_start < right.start_pos
            or (region_start == right.start_pos and region_end < right.end_pos)) then
        right = region
      end
    end
  end

  if target then return { target } end
  if left and right then return { left, right } end
  return {}
end

local function same_regions(a, b)
  if #a ~= #b then return false end

  for i = 1, #a do
    if a[i].id ~= b[i].id
        or a[i].start_pos ~= b[i].start_pos
        or a[i].end_pos ~= b[i].end_pos then
      return false
    end
  end

  return true
end

local function item_overlaps_regions(item_start, item_end, regions)
  for _, region in ipairs(regions) do
    if item_end > region.start_pos + EPSILON
        and item_start < region.end_pos - EPSILON then
      return true
    end
  end

  return false
end

local function items_touch(a, b)
  return a.track == b.track
    and (math.abs(a.end_pos - b.start_pos) <= EPSILON
      or math.abs(a.start_pos - b.end_pos) <= EPSILON)
end

local function set_item_lock(item, locked)
  if r.GetMediaItemInfo_Value(item, "C_LOCK") ~= locked then
    r.SetMediaItemInfo_Value(item, "C_LOCK", locked)
    return true
  end

  return false
end

local function apply_regions(project, regions)
  r.PreventUIRefresh(1)

  local changed = false

  if #regions == 0 then
    for _, saved in pairs(original_locks) do
      if r.ValidatePtr2(project, saved.item, "MediaItem*") then
        changed = set_item_lock(saved.item, saved.locked) or changed
      end
    end

    r.PreventUIRefresh(-1)
    if changed then r.UpdateArrange() end
    original_locks = {}
    return
  end

  local item_count = r.CountMediaItems(project)
  local items = {}

  for i = 0, item_count - 1 do
    local item = r.GetMediaItem(project, i)
    local item_start = r.GetMediaItemInfo_Value(item, "D_POSITION")
    local entry = {
      item = item,
      track = r.GetMediaItemTrack(item),
      start_pos = item_start,
      end_pos = item_start + r.GetMediaItemInfo_Value(item, "D_LENGTH")
    }
    entry.belongs = item_overlaps_regions(entry.start_pos, entry.end_pos, regions)
    entry.keep_unlocked = entry.belongs
    items[#items + 1] = entry
  end

  -- Propage l'accès de proche en proche à toute la chaîne d'items contigus.
  local propagated = true
  while propagated do
    propagated = false

    for _, entry in ipairs(items) do
      if not entry.keep_unlocked then
        for _, accessible_item in ipairs(items) do
          if accessible_item.keep_unlocked and items_touch(entry, accessible_item) then
            entry.keep_unlocked = true
            propagated = true
            break
          end
        end
      end
    end
  end

  for _, entry in ipairs(items) do
    local original_lock = remember_item(entry.item)
    local desired_lock = entry.keep_unlocked and original_lock or 1
    changed = set_item_lock(entry.item, desired_lock) or changed
  end

  r.PreventUIRefresh(-1)
  if changed then r.UpdateArrange() end
end

local function restore_original_locks(project)
  r.PreventUIRefresh(1)

  local changed = false
  for _, saved in pairs(original_locks) do
    if r.ValidatePtr2(project, saved.item, "MediaItem*") then
      changed = set_item_lock(saved.item, saved.locked) or changed
    end
  end

  r.PreventUIRefresh(-1)
  if changed then r.UpdateArrange() end
  original_locks = {}
end

local function initialize_project(project)
  current_project = project
  last_cursor_position = r.GetCursorPositionEx(project)
  active_regions = get_active_regions(project, last_cursor_position)
  apply_regions(project, active_regions)
  last_project_change = r.GetProjectStateChangeCount(project)
end

local function loop()
  local project = r.EnumProjects(-1)

  if project ~= current_project then
    restore_original_locks(current_project)
    initialize_project(project)
  else
    local cursor_position = r.GetCursorPositionEx(project)
    local project_change = r.GetProjectStateChangeCount(project)

    if cursor_position ~= last_cursor_position
        or project_change ~= last_project_change then
      local regions = get_active_regions(project, cursor_position)

      -- Un déplacement de région, d'item ou un changement de lock nécessite aussi
      -- une nouvelle passe, même si l'identifiant de région reste inchangé.
      if not same_regions(regions, active_regions)
          or project_change ~= last_project_change then
        active_regions = regions
        apply_regions(project, active_regions)
        project_change = r.GetProjectStateChangeCount(project)
      end

      last_cursor_position = cursor_position
      last_project_change = project_change
    end
  end

  r.defer(loop)
end

r.atexit(function()
  restore_original_locks(current_project)
  r.SetToggleCommandState(section_id, command_id, 0)
  r.RefreshToolbar2(section_id, command_id)
end)

initialize_project(current_project)
r.defer(loop)
