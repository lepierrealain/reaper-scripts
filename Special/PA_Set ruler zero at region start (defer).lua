-- @description Set ruler zero to region start when edit cursor enters a region (defer)
-- @author lepierrealain
-- @version 1.0
-- @about
--   Script toggle à laisser tourner en fond (toolbar ou __startup.lua).
--   Quand le curseur d'édition entre dans une région, place le zéro temporel du
--   projet au début de cette région. Le curseur est restauré immédiatement.

local r = reaper

local SET_ZERO_TO_CURSOR = 43345

local _, _, section_id, command_id = r.get_action_context()

-- Relancer l'action termine l'instance précédente au lieu d'afficher le dialogue
-- "script already running" (API disponible à partir de REAPER 7.03).
if r.set_action_options then r.set_action_options(1) end

r.SetToggleCommandState(section_id, command_id, 1)
r.RefreshToolbar2(section_id, command_id)

local current_project = r.EnumProjects(-1)
local regions_under_cursor = nil
local last_cursor_position = nil
local last_project_change = nil

-- Renvoie les régions contenant `position`.
local function get_regions_at_position(project, position)
  local found = {}
  local entry_count = r.CountProjectMarkers(project)

  for i = 0, entry_count - 1 do
    local ok, is_region, region_start, region_end, _, region_id =
      r.EnumProjectMarkers3(project, i)

    if ok ~= 0 and is_region and position >= region_start and position < region_end then
      found[region_id] = { start_pos = region_start, end_pos = region_end }
    end
  end

  return found
end

-- Parmi les régions nouvellement atteintes, choisit celle dont le début est le
-- plus tardif. Le comportement reste ainsi déterministe en cas de chevauchement.
local function get_new_target(found)
  local target = nil

  for region_id, region in pairs(found) do
    if not regions_under_cursor[region_id]
        and (not target
          or region.start_pos > target.start_pos
          or (region.start_pos == target.start_pos and region.end_pos < target.end_pos)) then
      target = region
    end
  end

  return target
end

local function set_zero_at(region_start, cursor_position)
  r.PreventUIRefresh(1)
  r.SetEditCurPos(region_start, false, false)
  r.Main_OnCommand(SET_ZERO_TO_CURSOR, 0)
  r.SetEditCurPos(cursor_position, false, false)
  r.PreventUIRefresh(-1)
  r.UpdateTimeline()
  r.UpdateArrange()
end

local function loop()
  local project = r.EnumProjects(-1)

  -- Un changement d'onglet n'est pas considéré comme une entrée de curseur dans
  -- une région : on initialise simplement l'état du nouveau projet.
  if project ~= current_project then
    current_project = project
    last_cursor_position = r.GetCursorPositionEx(project)
    regions_under_cursor = get_regions_at_position(project, last_cursor_position)
    last_project_change = r.GetProjectStateChangeCount(project)
  else
    local cursor_position = r.GetCursorPositionEx(project)
    local project_change = r.GetProjectStateChangeCount(project)

    -- Ne rescanner les marqueurs que si le curseur a bougé ou si les régions ont
    -- pu changer. Le defer reste ainsi très léger lorsque le projet est inactif.
    if cursor_position ~= last_cursor_position or project_change ~= last_project_change then
      local found = get_regions_at_position(project, cursor_position)
      local target = regions_under_cursor and get_new_target(found)

      if target then
        set_zero_at(target.start_pos, cursor_position)
        project_change = r.GetProjectStateChangeCount(project)
      end

      regions_under_cursor = found
      last_cursor_position = cursor_position
      last_project_change = project_change
    end
  end

  r.defer(loop)
end

r.atexit(function()
  r.SetToggleCommandState(section_id, command_id, 0)
  r.RefreshToolbar2(section_id, command_id)
end)

-- Lancer le script alors que le curseur est déjà dans une région ne modifie pas
-- le projet : le réglage se fera à la prochaine véritable entrée dans une région.
last_cursor_position = r.GetCursorPositionEx(current_project)
regions_under_cursor = get_regions_at_position(current_project, last_cursor_position)
last_project_change = r.GetProjectStateChangeCount(current_project)
r.defer(loop)
