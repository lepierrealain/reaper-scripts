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

-- Retourne l'index de la fixed lane sous la souris pour une track donnée, ou nil si pas en mode fixed lanes.
function PA_GetHoveredFixedLane(track)
  local lane_count = math.floor(reaper.GetMediaTrackInfo_Value(track, "I_NUMFIXEDLANES"))
  if lane_count <= 1 then return nil end

  local _, mouse_y  = reaper.GetMousePosition()
  local track_h     = reaper.GetMediaTrackInfo_Value(track, "I_WNDH")
  local tcp_y       = reaper.GetMediaTrackInfo_Value(track, "I_TCPY")
  local arrange_wnd = reaper.JS_Window_FindChildByID(reaper.GetMainHwnd(), 1000)
  local _, _, wnd_y = reaper.JS_Window_GetRect(arrange_wnd)
  local screen_y    = wnd_y + tcp_y
  local lane_h      = track_h / lane_count
  local rel_y       = mouse_y - screen_y
  return math.max(0, math.min(math.floor(rel_y / lane_h), lane_count - 1))
end

-- Retourne l'item et le temps sous la souris dans l'arrangeur, ou nil, nil.
-- En mode fixed lanes (I_NUMFIXEDLANES > 1), seuls les items de la lane survolée sont candidats.
function PA_GetItemUnderMouse()
  local track, mouse_time = PA_GetMouseArrangeContext()
  if not track or not mouse_time then return nil, nil end

  local hovered_lane = PA_GetHoveredFixedLane(track)

  local num_items = reaper.CountTrackMediaItems(track)
  for i = 0, num_items - 1 do
    local item       = reaper.GetTrackMediaItem(track, i)
    local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_end   = item_start + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    if mouse_time >= item_start and mouse_time < item_end then
      if hovered_lane == nil then
        return item, mouse_time
      end
      local item_lane = math.floor(reaper.GetMediaItemInfo_Value(item, "I_FIXEDLANE"))
      if item_lane == hovered_lane then
        return item, mouse_time
      end
    end
  end
  return nil, nil
end
