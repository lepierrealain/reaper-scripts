-- @description Solo and play track under mouse cursor (defer)
-- @author lepierrealain
-- @version 1.9

local lib_path = ({ reaper.get_action_context() })[2]:match("^(.+[\\/])")
local lib_root = lib_path .. ".." .. package.config:sub(1,1) .. "Libraries" .. package.config:sub(1,1)
dofile(lib_root .. "PA_lib_mouse.lua")

-- Le solo posé est un solo NORMAL : on ne touche pas aux solos que l'utilisateur a
-- posés lui-même, on ajoute simplement le nôtre. En contrepartie il faut retirer
-- nos propres solos quand on en pose un nouveau : on mémorise donc dans l'ExtState
-- les GUID des tracks soloées par le script. Ce retrait se fait playback arrêté et
-- APRÈS avoir posé le nouveau solo, pour ne jamais laisser toutes les pistes
-- ouvertes, même une fraction de seconde.
--
-- L'arrêt (set_action_options) d'une instance précédente n'est pas synchrone : quand
-- cette instance-ci démarre, l'ancienne peut encore être en vie un moment, et son
-- atexit tardif retirerait un solo qu'on vient de poser (cas où l'on re-solo la même
-- track). D'où le numéro de génération : seule la DERNIÈRE instance de la chaîne
-- nettoie, les atexit des instances intermédiaires tuées entretemps sont ignorés.
local EXT_NS = "PA_SoloPlayTrackUnderMouse"

local function track_from_guid(guid)
  for i = 0, reaper.CountTracks(0) - 1 do
    local t = reaper.GetTrack(0, i)
    if reaper.GetTrackGUID(t) == guid then return t end
  end
end

-- Retire les solos posés par le script (et eux seuls), sauf celui de `keep` s'il
-- est fourni. Ne rafraîchit pas l'affichage : c'est à l'appelant de le faire une
-- seule fois, une fois l'état de solo définitif.
local function clear_own_solos(keep_guid)
  local guids = reaper.GetExtState(EXT_NS, "soloed")
  if guids == "" then return end
  for guid in guids:gmatch("[^;]+") do
    if guid ~= keep_guid then
      local t = track_from_guid(guid)
      if t then reaper.CSurf_OnSoloChange(t, 0) end
    end
  end
  reaper.DeleteExtState(EXT_NS, "soloed", false)
end

local my_gen = (tonumber(reaper.GetExtState(EXT_NS, "gen")) or 0) + 1
reaper.SetExtState(EXT_NS, "gen", tostring(my_gen), false)

-- 1 = tuer l'instance déjà en cours au lieu d'afficher la boîte de dialogue
-- 2 = ET relancer aussitôt le script. Sans le bit 2, une 2e pression se contentait
--     de tuer la 1re instance sans en démarrer de nouvelle : d'où un coup sur deux
--     (2, 4, 6...) sans solo ni lecture.
if reaper.set_action_options then reaper.set_action_options(1 | 2) end

local has_started = false  -- passe à true dès que le playback a démarré

local function is_playing()
  local state = reaper.GetPlayState()
  return state & 1 == 1 or state & 4 == 4
end

local function loop()
  if not has_started then
    -- On attend que le playback démarre
    if is_playing() then has_started = true end
    reaper.defer(loop)
    return
  end

  -- Le playback a démarré : on attend qu'il s'arrête
  if is_playing() then
    reaper.defer(loop)
    return
  end
end

local function main()
  local track, mouse_time = PA_GetMouseArrangeContext()
  if not track then return end

  -- Le playback de l'instance précédente tourne encore : on l'arrête AVANT de
  -- toucher aux solos, sinon le court instant où l'ancien solo est retiré et le
  -- nouveau pas encore posé s'entend (toutes les pistes s'ouvrent une fraction
  -- de seconde).
  if is_playing() then reaper.OnStopButtonEx(0) end

  -- Solo normal : on pose le nouveau solo d'abord, puis on retire ceux des
  -- exécutions précédentes (jamais l'inverse, pour ne jamais passer par un état
  -- sans aucun solo). Les solos posés par l'utilisateur ne sont pas touchés.
  --
  -- CSurf_OnSoloChange et non SetMediaTrackInfo_Value(..., "I_SOLO", 1) : le second
  -- écrit le flag brut en mode "solo simple", qui coupe aussi les bus dans lesquels
  -- la piste est routée (le Mix se retrouvait muté). CSurf_OnSoloChange emprunte le
  -- même chemin qu'un clic sur le bouton solo, donc il respecte la préférence
  -- "solo in place" de l'utilisateur et met à jour les parents de dossier.
  local target_guid = reaper.GetTrackGUID(track)
  reaper.CSurf_OnSoloChange(track, 1)
  clear_own_solos(target_guid)
  reaper.SetExtState(EXT_NS, "soloed", target_guid, false)
  reaper.TrackList_AdjustWindows(false)

  reaper.SetEditCurPos(mouse_time, false, true)
  reaper.OnPlayButtonEx(0)

  reaper.defer(loop)
end

reaper.atexit(function()
  -- Ne nettoie que si aucune instance plus récente n'a pris le relais.
  if tostring(my_gen) == reaper.GetExtState(EXT_NS, "gen") then
    clear_own_solos()
    reaper.TrackList_AdjustWindows(false)
    reaper.DeleteExtState(EXT_NS, "gen", false)
  end
end)

main()
