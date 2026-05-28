-- @description Mouse functions
-- @author lepierrealain
-- @version 1.0

-- Bibliothèque utilitaire : contexte souris dans l'arrangeur REAPER
-- Importable via : dofile(reaper.GetResourcePath() .. "/Scripts/...chemin.../PA_lib_mouse.lua")
-- Seules les fonctions sont définies ici ; aucun code n'est exécuté à l'import.

-- Retourne la track et le temps sous la souris dans l'arrangeur.
-- Retourne nil, nil si la souris n'est pas dans l'arrangeur.
function PA_GetMouseArrangeContext()
  local window, segment, details = reaper.BR_GetMouseCursorContext()
  if window ~= "arrange" then return nil, nil end

  local mouse_time = reaper.BR_GetMouseCursorContext_Position()
  if not mouse_time then return nil, nil end

  local mouse_x, mouse_y = reaper.GetMousePosition()
  local track = reaper.GetTrackFromPoint(mouse_x, mouse_y)

  return track, mouse_time
end

-- Retourne l'item sous la souris dans l'arrangeur, ou nil.
function PA_GetItemUnderMouse()
  local track, mouse_time = PA_GetMouseArrangeContext()
  if not track or not mouse_time then return nil end

  local num_items = reaper.CountTrackMediaItems(track)
  for i = 0, num_items - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_end   = item_start + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    if mouse_time >= item_start and mouse_time < item_end then
      return item
    end
  end
  return nil
end
