-- @description Edit visible items on selected tracks under mouse cursor (toggle)
-- @author lepierrealain
-- @version 1.0
-- @about
--   Active les éditions sous la souris sur la piste survolée et les pistes sélectionnées.
--   Un item par piste, au temps souris ou voisin du côté édité pour les trims/fondus.
--   Ignore les items hors écran, les lanes cachées et les items verrouillés.
--   Compatible avec trim gauche/droit, fondus, split, snap offset et copie du voisin gauche.
--   Relancer l'action la désactive. Son bouton de toolbar reste allumé tant qu'elle tourne.
--   Nécessite js_ReaScriptAPI pour limiter les éditions à la zone visible.

local _, _, section_id, command_id = reaper.get_action_context()
if reaper.set_action_options then reaper.set_action_options(1) end

if not reaper.JS_Window_FindChildByID or not reaper.JS_Window_GetClientRect then
  reaper.ShowMessageBox("Ce mode nécessite js_ReaScriptAPI pour limiter les éditions aux items visibles.",
    "Édition sur les pistes sélectionnées", 0)
  return
end

reaper.atexit(function()
  reaper.DeleteExtState("PA_MouseEditing", "selected_tracks", false)
  reaper.SetToggleCommandState(section_id, command_id, 0)
  reaper.RefreshToolbar2(section_id, command_id)
end)

reaper.SetExtState("PA_MouseEditing", "selected_tracks", "1", false)
reaper.SetToggleCommandState(section_id, command_id, 1)
reaper.RefreshToolbar2(section_id, command_id)

local function loop()
  reaper.defer(loop)
end
reaper.defer(loop)
