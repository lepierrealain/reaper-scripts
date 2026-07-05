-- @description Auto colorize tracks from palette (background watcher)
-- @author lepierrealain
-- @version 1.0
-- @about
--   Script toggle à laisser tourner en fond (toolbar ou __startup.lua).
--   Colorise toutes les pistes du projet à partir de la palette définie dans
--   "PA_Auto colorize tracks (settings)" : couleurs en boucle ou aléatoires
--   (stables par piste), enfants déclinés depuis la couleur de leur parent.
--   Une passe est appliquée au lancement, puis dès qu'une piste est ajoutée,
--   supprimée ou déplacée dans l'arborescence, ou que les réglages changent.
--   Avec l'option "préserver", les couleurs posées à la main par l'utilisateur
--   ne sont jamais écrasées.

local lib_path = ({ reaper.get_action_context() })[2]:match("^(.+[\\/])")
local lib_root = lib_path .. ".." .. package.config:sub(1, 1) .. "Libraries" .. package.config:sub(1, 1)
dofile(lib_root .. "PA_lib_color.lua")

local _, _, section_id, cmd_id = reaper.get_action_context()

-- Relancer l'action termine l'instance précédente au lieu d'afficher le dialogue REAPER
if reaper.set_action_options then reaper.set_action_options(1) end

reaper.SetToggleCommandState(section_id, cmd_id, 1)
reaper.RefreshToolbar2(section_id, cmd_id)

local CHECK_INTERVAL = 0.5  -- secondes entre deux scans

local last_check = 0
local last_sig = nil  -- nil au départ : première passe immédiate

-- Signature légère : réglages (stamp) + structure des pistes (GUID + profondeur).
-- Les couleurs n'en font pas partie : une retouche manuelle de couleur ne
-- déclenche pas de repasse (c'est l'option "préserver" qui protège, à la passe suivante).
local function signature()
  local parts = { PA_ColorStamp() }
  for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    parts[#parts + 1] = reaper.GetTrackGUID(track) .. reaper.GetTrackDepth(track)
  end
  return table.concat(parts)
end

local function loop()
  local now = reaper.time_precise()
  if now - last_check >= CHECK_INTERVAL then
    last_check = now
    local sig = signature()
    if sig ~= last_sig then
      last_sig = sig
      PA_ColorizeApply(PA_ColorLoadSettings(), false)
    end
  end
  reaper.defer(loop)
end

reaper.atexit(function()
  reaper.SetToggleCommandState(section_id, cmd_id, 0)
  reaper.RefreshToolbar2(section_id, cmd_id)
end)

reaper.defer(loop)
