-- @description Track utility functions
-- @author lepierrealain
-- @version 1.1

-- I_RECINPUT: 4096 | channel (0=all) | (input << 5)
-- input 63 = all devices, channel 0 = all channels
local MIDI_INPUT_ALL = 4096 | 0 | (63 << 5)

-- Nom de la piste destination du send de monitoring audio
local SEND_DEST_NAME = "Headphone PA"

-- Cas particulier : une piste talkback est monitorée sur le casque invité,
-- jamais sur le casque PA, et ne doit jamais enregistrer.
local TALKBACK_DEST_NAME = "Headphone invité"

-- Retourne la première piste du projet nommée `name`, ou nil.
local function getTrackByName(name)
  for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    local _, track_name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
    if track_name == name then return track end
  end
  return nil
end

-- Cherche un send de `track` vers la piste `dest` ; retourne son index ou nil.
local function findSendToTrack(track, dest)
  for i = 0, reaper.GetTrackNumSends(track, 0) - 1 do
    if reaper.GetTrackSendInfo_Value(track, 0, i, "P_DESTTRACK") == dest then
      return i
    end
  end
  return nil
end

-- Supprime le send de `track` vers la piste de monitoring, s'il existe.
local function removeMonitorSend(track, dest)
  if not dest then return end
  local idx = findSendToTrack(track, dest)
  if idx then
    reaper.RemoveTrackSend(track, 0, idx)
  end
end

-- Retourne la piste de monitoring casque (SEND_DEST_NAME), ou nil si absente.
function PA_GetMonitorTrack()
  return getTrackByName(SEND_DEST_NAME)
end

-- Marqueur P_EXT posé sur les pistes "invité" : armées mais sans send casque,
-- le monitoring passe par une piste dédiée. Le watcher ne doit pas y toucher.
local GUEST_FLAG = "P_EXT:PA_guest"
local GUEST_MONITOR_FLAG = "P_EXT:PA_guest_monitor"

function PA_IsGuestTrack(track)
  local _, v = reaper.GetSetMediaTrackInfo_String(track, GUEST_FLAG, "", false)
  return v == "1"
end

local function setGuestFlag(track, on)
  reaper.GetSetMediaTrackInfo_String(track, GUEST_FLAG, on and "1" or "", true)
end

-- Marqueur P_EXT posé par les fonctions template : la piste a déjà été
-- configurée par "Set track template". Le watcher applique automatiquement
-- un template aux pistes armées qui ne l'ont pas encore.
local TEMPLATE_FLAG = "P_EXT:PA_template"

function PA_HasTemplateFlag(track)
  local _, v = reaper.GetSetMediaTrackInfo_String(track, TEMPLATE_FLAG, "", false)
  return v == "1"
end

local function setTemplateFlag(track)
  reaper.GetSetMediaTrackInfo_String(track, TEMPLATE_FLAG, "1", true)
end

-- true si `track` est une piste de monitoring guest créée par la lib.
function PA_IsGuestMonitorTrack(track)
  local _, v = reaper.GetSetMediaTrackInfo_String(track, GUEST_MONITOR_FLAG, "", false)
  return v == "1"
end

-- Supprime la piste de monitoring guest située juste au-dessus de `track`, si présente.
-- Retourne true si une piste a été supprimée.
local function removeGuestMonitorTrack(track)
  local idx = math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")) - 1  -- 1-based → 0-based
  if idx <= 0 then return false end
  local above = reaper.GetTrack(0, idx - 1)
  local _, flag = reaper.GetSetMediaTrackInfo_String(above, GUEST_MONITOR_FLAG, "", false)
  if flag == "1" then
    reaper.DeleteTrack(above)
    return true
  end
  return false
end

-- true si `input` (valeur I_RECINPUT) est un input audio.
function PA_IsAudioInput(input)
  return input >= 0 and (math.floor(input) & 4096) == 0
end

-- Marqueur P_EXT posé par le bouton Talkback : la piste est monitorée sur le
-- casque invité et reste toujours en record disable.
local TALKBACK_FLAG = "P_EXT:PA_talkback"

function PA_IsTalkbackTrack(track)
  local _, v = reaper.GetSetMediaTrackInfo_String(track, TALKBACK_FLAG, "", false)
  return v == "1"
end

local function setTalkbackFlag(track, on)
  reaper.GetSetMediaTrackInfo_String(track, TALKBACK_FLAG, on and "1" or "", true)
end

-- Record mode normal, sauf les pistes talkback qui restent toujours en record disable.
local function applyRecMode(track)
  reaper.SetMediaTrackInfo_Value(track, "I_RECMODE", PA_IsTalkbackTrack(track) and 2 or 0)
end

-- Routing "track armée" : sortie du mix parent + send vers la piste de monitoring.
-- Une piste talkback part vers le casque invité et passe en record disable.
-- Silencieux si la destination est nil/introuvable.
function PA_ApplyInputRouting(track, dest)
  if PA_IsTalkbackTrack(track) then
    removeMonitorSend(track, dest)  -- jamais vers le casque PA : nettoie un éventuel send existant
    dest = getTrackByName(TALKBACK_DEST_NAME)
    reaper.SetMediaTrackInfo_Value(track, "I_RECMODE", 2)  -- record disable (monitor only)
  else
    removeMonitorSend(track, getTrackByName(TALKBACK_DEST_NAME))  -- nettoie un éventuel send talkback
  end

  reaper.SetMediaTrackInfo_Value(track, "B_MAINSEND", 0)
  if dest and track ~= dest and not findSendToTrack(track, dest) then
    reaper.CreateTrackSend(track, dest)
  end
end

-- Routing normal : retour dans le mix parent, sans send vers la piste de monitoring.
-- Une piste talkback reste en record disable.
function PA_RemoveInputRouting(track, dest)
  if PA_IsTalkbackTrack(track) then
    removeMonitorSend(track, dest)  -- nettoie aussi un éventuel send vers le casque PA
    dest = getTrackByName(TALKBACK_DEST_NAME)
    reaper.SetMediaTrackInfo_Value(track, "I_RECMODE", 2)  -- record disable (monitor only)
  else
    removeMonitorSend(track, getTrackByName(TALKBACK_DEST_NAME))  -- nettoie un éventuel send talkback
  end

  reaper.SetMediaTrackInfo_Value(track, "B_MAINSEND", 1)
  removeMonitorSend(track, dest)
end

-- Résout la valeur I_RECINPUT audio d'une piste :
-- recinput explicite si fourni (canal 0-based, | 1024 pour une paire stéréo),
-- sinon input audio actuel, sinon celui sauvegardé avant le passage en MIDI,
-- sinon Input 1.
local function resolveAudioInput(track, recinput)
  if recinput then return recinput end

  local cur = reaper.GetMediaTrackInfo_Value(track, "I_RECINPUT")
  if PA_IsAudioInput(cur) then return cur end  -- déjà un input audio, on le garde

  local ok, saved = reaper.GetSetMediaTrackInfo_String(track, "P_EXT:PA_audio_input", "", false)
  local n = tonumber(saved)
  if ok and n then return n end

  return 0  -- Input 1 par défaut
end

-- Cœur du template Input pour une piste (sans les toggles globaux).
-- talkback = true : piste monitorée sur le casque invité, record disable.
local function applyInputTemplate(track, dest, recinput, talkback)
  removeGuestMonitorTrack(track)
  reaper.SetMediaTrackInfo_Value(track, "I_RECINPUT", resolveAudioInput(track, recinput))
  setGuestFlag(track, false)
  setTalkbackFlag(track, talkback or false)
  applyRecMode(track)
  setTemplateFlag(track)
  reaper.SetMediaTrackInfo_Value(track, "I_RECMON", 1)  -- monitoring toujours on en Self/Talkback
  PA_ApplyInputRouting(track, dest)
  reaper.SetMediaTrackInfo_Value(track, "I_RECARM", 1)
end

-- Loop commun aux templates Input (Self et Talkback).
local function setTrackTemplateToInput(recinput, talkback, title)
  local count = reaper.CountSelectedTracks(0)
  if count == 0 then
    reaper.ShowMessageBox("No track selected.", title, 0)
    return
  end

  local dest = PA_GetMonitorTrack()  -- nil : pas de send, silencieux

  -- Copier la sélection d'abord : la suppression de pistes décale les index
  local tracks = {}
  for i = 0, count - 1 do
    tracks[#tracks + 1] = reaper.GetSelectedTrack(0, i)
  end

  for _, track in ipairs(tracks) do
    if reaper.ValidatePtr2(0, track, "MediaTrack*") then
      -- Désactiver l'auto record arm s'il est actif
      if reaper.GetToggleCommandState(40736) == 1 then
        reaper.Main_OnCommand(40736, 0)
      end

      applyInputTemplate(track, dest, recinput, talkback)
    end
  end

  reaper.TrackList_AdjustWindows(false)
end

-- Configure les pistes sélectionnées pour l'enregistrement audio (arm, sans auto record arm).
-- recinput = nil : conserve/restaure l'input audio de chaque piste (Input 1 par défaut).
-- Sinon : valeur I_RECINPUT (canal 0-based, | 1024 pour une paire stéréo).
function PA_SetTrackTemplateToInput(recinput)
  setTrackTemplateToInput(recinput, false, "Set track to Audio")
end

-- Configure les pistes sélectionnées en talkback : armées mais record disable
-- (monitor only), monitorées sur le casque invité, jamais sur le casque PA.
function PA_SetTrackTemplateToTalkbackInput(recinput)
  setTrackTemplateToInput(recinput, true, "Set track to Talkback")
end

-- Crée (ou réutilise) la piste de monitoring juste au-dessus de `track` :
-- armée sur le même `input`, monitor on, record disable, send vers `dest`,
-- hors mix parent. Marquée GUEST_MONITOR_FLAG pour être réutilisée.
-- Retourne true si une piste a été créée.
local function ensureGuestMonitorTrack(track, input, dest)
  local idx = math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")) - 1  -- 1-based → 0-based

  local mon, created = nil, false
  if idx > 0 then
    local above = reaper.GetTrack(0, idx - 1)
    local _, flag = reaper.GetSetMediaTrackInfo_String(above, GUEST_MONITOR_FLAG, "", false)
    if flag == "1" then mon = above end
  end

  if not mon then
    reaper.InsertTrackAtIndex(idx, true)
    mon = reaper.GetTrack(0, idx)
    local _, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
    reaper.GetSetMediaTrackInfo_String(mon, "P_NAME", "Monitor " .. name, true)
    reaper.GetSetMediaTrackInfo_String(mon, GUEST_MONITOR_FLAG, "1", true)
    created = true
  end

  reaper.SetMediaTrackInfo_Value(mon, "I_RECINPUT", input)
  reaper.SetMediaTrackInfo_Value(mon, "I_RECMODE", 2)  -- record disable (monitor only)
  reaper.SetMediaTrackInfo_Value(mon, "I_RECMON", 1)
  reaper.SetMediaTrackInfo_Value(mon, "I_RECARM", 1)
  reaper.SetMediaTrackInfo_Value(mon, "B_MAINSEND", 0)
  if dest and not findSendToTrack(mon, dest) then
    reaper.CreateTrackSend(mon, dest)
  end

  return created
end

-- Versions publiques pour le watcher (defer) : gèrent la piste de monitoring
-- d'une piste guest quand elle est (dés)armée à la main.
-- Retournent true si une piste a été créée/supprimée.
function PA_EnsureGuestMonitorTrack(track, dest)
  local input = reaper.GetMediaTrackInfo_Value(track, "I_RECINPUT")
  if not PA_IsAudioInput(input) then return false end
  return ensureGuestMonitorTrack(track, input, dest)
end

function PA_RemoveGuestMonitorTrack(track)
  return removeGuestMonitorTrack(track)
end

-- Configure les pistes sélectionnées pour l'enregistrement d'un invité :
-- piste armée, monitoring off, sans send casque (mix parent normal), plus une
-- piste de monitoring dédiée juste au-dessus (même input, monitor on,
-- record disable, send vers Headphone PA).
-- recinput : même convention que PA_SetTrackTemplateToInput.
function PA_SetTrackTemplateToGuestInput(recinput)
  local count = reaper.CountSelectedTracks(0)
  if count == 0 then
    reaper.ShowMessageBox("No track selected.", "Set track to Audio (guest)", 0)
    return
  end

  local dest = PA_GetMonitorTrack()

  -- Copier la sélection d'abord : l'insertion de pistes décale les index
  local tracks = {}
  for i = 0, count - 1 do
    tracks[#tracks + 1] = reaper.GetSelectedTrack(0, i)
  end

  for _, track in ipairs(tracks) do
    local input = resolveAudioInput(track, recinput)
    reaper.SetMediaTrackInfo_Value(track, "I_RECINPUT", input)
    setTalkbackFlag(track, false)
    applyRecMode(track)
    reaper.SetMediaTrackInfo_Value(track, "I_RECMON", 0)  -- le monitoring passe par la piste dédiée
    setGuestFlag(track, true)
    setTemplateFlag(track)
    PA_RemoveInputRouting(track, dest)  -- mix parent, pas de send casque

    -- Désactiver l'auto record arm s'il est actif
    if reaper.GetToggleCommandState(40736) == 1 then
      reaper.Main_OnCommand(40736, 0)
    end

    reaper.SetMediaTrackInfo_Value(track, "I_RECARM", 1)

    ensureGuestMonitorTrack(track, input, dest)
  end

  reaper.TrackList_AdjustWindows(false)
end

-- Configure les pistes sélectionnées en Input audio désarmé (parent send, sans send monitoring).
-- recinput : même convention que PA_SetTrackTemplateToInput.
function PA_SetTrackTemplateToInputIdle(recinput)
  local count = reaper.CountSelectedTracks(0)
  if count == 0 then
    reaper.ShowMessageBox("No track selected.", "Set track to Audio (idle)", 0)
    return
  end

  local dest = PA_GetMonitorTrack()

  -- Copier la sélection d'abord : la suppression de pistes décale les index
  local tracks = {}
  for i = 0, count - 1 do
    tracks[#tracks + 1] = reaper.GetSelectedTrack(0, i)
  end

  for _, track in ipairs(tracks) do
    if reaper.ValidatePtr2(0, track, "MediaTrack*") then
      removeGuestMonitorTrack(track)
      reaper.SetMediaTrackInfo_Value(track, "I_RECINPUT", resolveAudioInput(track, recinput))
      setGuestFlag(track, false)
      setTalkbackFlag(track, false)
      applyRecMode(track)
      setTemplateFlag(track)
      reaper.SetMediaTrackInfo_Value(track, "I_RECARM", 0)
      PA_RemoveInputRouting(track, dest)
    end
  end

  reaper.TrackList_AdjustWindows(false)
end

-- Ouvre le FX dont le nom contient `search` sur la piste sélectionnée.
-- Si absent, l'ajoute via `plugin_name` (nom exact tel que retourné par EnumInstalledFX).
function PA_ShowOrAddFX(search, plugin_name)
  local track = reaper.GetSelectedTrack(0, 0)
  if not track then return end

  local fx_count = reaper.TrackFX_GetCount(track)
  for i = 0, fx_count - 1 do
    local _, name = reaper.TrackFX_GetFXName(track, i)
    if name:lower():find(search:lower(), 1, true) then
      reaper.TrackFX_Show(track, i, 3)
      return
    end
  end

  reaper.Undo_BeginBlock()
  local idx = reaper.TrackFX_AddByName(track, plugin_name, false, -1)
  reaper.Undo_EndBlock("Add " .. plugin_name, -1)
  if idx >= 0 then
    reaper.TrackFX_Show(track, idx, 3)
  end
end

-- Cœur du template MIDI pour une piste (sans le toggle global d'auto record arm).
local function applyMidiTemplate(track, dest)
  removeGuestMonitorTrack(track)

  -- Mémoriser l'input audio courant pour le restaurer au retour du MIDI
  local cur = reaper.GetMediaTrackInfo_Value(track, "I_RECINPUT")
  if PA_IsAudioInput(cur) then
    reaper.GetSetMediaTrackInfo_String(track, "P_EXT:PA_audio_input",
      tostring(math.floor(cur)), true)
  end

  reaper.SetMediaTrackInfo_Value(track, "I_RECINPUT", MIDI_INPUT_ALL)
  setGuestFlag(track, false)
  setTalkbackFlag(track, false)
  applyRecMode(track)
  setTemplateFlag(track)
  reaper.SetMediaTrackInfo_Value(track, "I_RECMON", 1)  -- input monitoring on (MIDI)
  PA_RemoveInputRouting(track, dest)
end

-- Applique le template adapté à une piste que le watcher voit armée sans
-- marquage template : MIDI si un instrument (VSTi/CLAPi) est présent, sinon
-- Input audio (input conservé/restauré, routing casque, monitoring on).
-- Ne touche pas aux options globales (auto record arm).
function PA_AutoApplyTemplate(track, dest)
  if reaper.TrackFX_GetInstrument(track) >= 0 then
    applyMidiTemplate(track, dest)
  else
    applyInputTemplate(track, dest, nil)
  end
end

-- Configure les pistes sélectionnées pour l'enregistrement MIDI (All MIDI, auto record arm).
function PA_SetTrackTemplateToMidi()
  local count = reaper.CountSelectedTracks(0)
  if count == 0 then
    reaper.ShowMessageBox("No track selected.", "Set track to MIDI", 0)
    return
  end

  local dest = PA_GetMonitorTrack()

  -- Copier la sélection d'abord : la suppression de pistes décale les index
  local tracks = {}
  for i = 0, count - 1 do
    tracks[#tracks + 1] = reaper.GetSelectedTrack(0, i)
  end

  for _, track in ipairs(tracks) do
    if reaper.ValidatePtr2(0, track, "MediaTrack*") then
      applyMidiTemplate(track, dest)
    end
  end

  reaper.TrackList_AdjustWindows(false)

  if reaper.GetToggleCommandState(40736) ~= 1 then
    reaper.Main_OnCommand(40736, 0)
  end
end
