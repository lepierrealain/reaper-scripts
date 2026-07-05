-- @description Watch record-armed audio tracks and keep monitor routing in sync
-- @author lepierrealain
-- @version 1.1
-- @about
--   Script toggle à laisser tourner en fond (toolbar ou __startup.lua).
--   Dès qu'une piste est armée avec un input audio — même à la main, sans passer
--   par les scripts template — elle sort du mix parent et reçoit un send vers la
--   piste de monitoring casque ("Headphone PA"). Au désarmement (ou passage en MIDI),
--   le routing normal est restauré. Ne touche jamais aux pistes qu'il n'a pas
--   vues armées pendant sa session.
--   Pistes guest (marquées par le bouton Guest du template) : pas de send casque ;
--   à la place, leur piste de monitoring dédiée est recréée au réarmement et
--   supprimée au désarmement.

local lib_path = ({ reaper.get_action_context() })[2]:match("^(.+[\\/])")
local lib_root = lib_path .. ".." .. package.config:sub(1,1) .. "Libraries" .. package.config:sub(1,1)
dofile(lib_root .. "PA_lib_track.lua")

local _, _, section_id, cmd_id = reaper.get_action_context()

-- Relancer l'action termine l'instance précédente au lieu d'afficher le dialogue REAPER
if reaper.set_action_options then reaper.set_action_options(1) end

reaper.SetToggleCommandState(section_id, cmd_id, 1)
reaper.RefreshToolbar2(section_id, cmd_id)

local CHECK_INTERVAL = 0.2  -- secondes entre deux scans

local prev = {}  -- GUID → true si la piste était armée avec input audio au dernier scan
local last_check = 0

local function isArmedAudio(track)
  return reaper.GetMediaTrackInfo_Value(track, "I_RECARM") == 1
     and PA_IsAudioInput(reaper.GetMediaTrackInfo_Value(track, "I_RECINPUT"))
end

local function scan()
  local dest = PA_GetMonitorTrack()
  local seen = {}
  local layout_changed = false

  for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    -- La borne du for est figée : si une piste monitor vient d'être supprimée
    -- pendant ce scan, les derniers index peuvent être vides.
    if not track then break end
    if track ~= dest then
      local guid = reaper.GetTrackGUID(track)
      local armed = isArmedAudio(track)
      seen[guid] = armed

      if not PA_HasTemplateFlag(track) and not PA_IsGuestMonitorTrack(track) then
        -- Piste jamais configurée par "Set track template" : à l'armement,
        -- appliquer automatiquement le template comme la version (quick) —
        -- MIDI si un instrument est présent, sinon Input audio + routing casque.
        local rec_armed = reaper.GetMediaTrackInfo_Value(track, "I_RECARM") == 1
        seen[guid] = rec_armed
        if rec_armed and prev[guid] ~= true then
          PA_AutoApplyTemplate(track, dest)
        end
      elseif PA_IsGuestTrack(track) then
        -- Piste guest : pas de send casque (monitoring via sa piste dédiée).
        -- On synchronise seulement la piste de monitoring avec l'état d'armement.
        if armed and prev[guid] ~= true then
          layout_changed = PA_EnsureGuestMonitorTrack(track, dest) or layout_changed
        elseif not armed and prev[guid] == true then
          layout_changed = PA_RemoveGuestMonitorTrack(track) or layout_changed
        end
      else
        if armed and prev[guid] ~= true then
          PA_ApplyInputRouting(track, dest)
        elseif not armed and prev[guid] == true then
          PA_RemoveInputRouting(track, dest)
        end
      end
    end
  end

  if layout_changed then
    reaper.TrackList_AdjustWindows(false)
  end

  prev = seen
end

local function loop()
  local now = reaper.time_precise()
  if now - last_check >= CHECK_INTERVAL then
    last_check = now
    scan()
  end
  reaper.defer(loop)
end

reaper.atexit(function()
  reaper.SetToggleCommandState(section_id, cmd_id, 0)
  reaper.RefreshToolbar2(section_id, cmd_id)
end)

reaper.defer(loop)
