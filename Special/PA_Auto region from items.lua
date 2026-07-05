-- @description Automatically add region from items from tracks (background watcher)
-- @author lepierrealain
-- @version 3.0
-- @about
--   Script toggle à laisser tourner en fond (toolbar ou __startup.lua).
--   Maintient les régions synchronisées avec les items des pistes configurées
--   dans "PA_Auto region from items (settings)" : création, déplacement,
--   renommage et suppression suivent les items en continu. Recharge l'état du
--   projet quand les réglages changent (stamp) ou au changement d'onglet.

local lib_path = ({ reaper.get_action_context() })[2]:match("^(.+[\\/])")
local lib_root = lib_path .. ".." .. package.config:sub(1, 1) .. "Libraries" .. package.config:sub(1, 1)
dofile(lib_root .. "PA_lib_autoregion.lua")

local _, _, section_id, cmd_id = reaper.get_action_context()

-- Relancer l'action termine l'instance précédente au lieu d'afficher le
-- dialogue "script already running" (API dispo à partir de REAPER 7.03).
if reaper.set_action_options then reaper.set_action_options(1) end

if not reaper.BR_GetMediaItemGUID then
  reaper.ShowMessageBox(
    "Ce script nécessite l'extension SWS.\nTéléchargeable sur https://www.sws-extension.org/",
    "AutoRegionFromItems", 0)
  return
end

reaper.SetToggleCommandState(section_id, cmd_id, 1)
reaper.RefreshToolbar2(section_id, cmd_id)

local state             = PA_AR_LoadState()
local prev, prev_s      = {}, {}
local last_change_count = -1   -- GetProjectStateChangeCount du dernier tick traité
local last_stamp        = PA_AR_Stamp()
local cur_proj          = reaper.EnumProjects(-1)

-- Recharge l'état du projet courant et resynchronise les régions
-- (réglages modifiés, changement d'onglet, démarrage).
local function reload()
  state = PA_AR_LoadState()
  if #state.guids > 0 then
    prev, prev_s = PA_AR_Resync(state)
  else
    -- Projet sans config : ne pas resynchroniser, pour ne pas écrire
    -- d'ExtState (le projet serait marqué modifié par un simple
    -- changement d'onglet).
    prev, prev_s = {}, {}
  end
  -- Relire le compteur après nos propres modifications (régions, ExtState)
  -- pour ne pas déclencher un passage inutile au tick suivant.
  last_change_count = reaper.GetProjectStateChangeCount(0)
end

-- Un passage incrémental : validation, snapshot, diff, persistance.
local function runTick()
  PA_AR_ValidateMappings(state, prev)
  local curr, curr_s = PA_AR_BuildSnapshot(state)
  local changed = PA_AR_ApplyDiff(prev, curr, prev_s, curr_s, state)

  prev, prev_s = curr, curr_s

  if changed then
    PA_AR_SaveState(state)
    reaper.UpdateArrange()
  end

  last_change_count = reaper.GetProjectStateChangeCount(0)
end

local function loop()
  local proj  = reaper.EnumProjects(-1)
  local stamp = PA_AR_Stamp()

  if proj ~= cur_proj or stamp ~= last_stamp then
    cur_proj, last_stamp = proj, stamp
    reload()
  elseif reaper.GetProjectStateChangeCount(0) ~= last_change_count then
    -- Rien n'a changé dans le projet depuis le dernier passage → pas de travail.
    runTick()
  end

  reaper.defer(loop)
end

reaper.atexit(function()
  reaper.SetToggleCommandState(section_id, cmd_id, 0)
  reaper.RefreshToolbar2(section_id, cmd_id)
end)

reload()
reaper.defer(loop)
