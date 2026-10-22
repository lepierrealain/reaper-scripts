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

-- En free item positioning, limite la recherche d'un item voisin à la hauteur
-- survolée. Hors de ce mode, tous les items restent candidats.
function PA_IsItemAtMouseHeight(track, item)
  if reaper.GetMediaTrackInfo_Value(track, "I_FREEMODE") ~= 1 then return true end

  local _, mouse_y = reaper.GetMousePosition()
  local tcp_y = reaper.GetMediaTrackInfo_Value(track, "I_TCPY")
  local arrange_wnd = reaper.JS_Window_FindChildByID(reaper.GetMainHwnd(), 1000)
  local _, _, wnd_y = reaper.JS_Window_GetRect(arrange_wnd)
  local rel_y = mouse_y - (wnd_y + tcp_y)
  local item_y = reaper.GetMediaItemInfo_Value(item, "I_LASTY")
  local item_h = reaper.GetMediaItemInfo_Value(item, "I_LASTH")
  return rel_y >= item_y and rel_y < item_y + item_h
end

function PA_SelectItemIfFreeModeAndNoneSelected(track, item, num_selected)
  if item and num_selected == 0
    and reaper.GetMediaTrackInfo_Value(track, "I_FREEMODE") == 1 then
    reaper.SetMediaItemSelected(item, true)
  end
end

-- Retourne l'item et le temps sous la souris dans l'arrangeur, ou nil, nil.
-- En mode fixed lanes (I_NUMFIXEDLANES > 1), seuls les items de la lane survolée sont candidats.
-- En free item positioning, utilise les coordonnées écran pour distinguer les items superposés.
function PA_GetItemUnderMouse()
  local track, mouse_time = PA_GetMouseArrangeContext()
  if not track or not mouse_time then return nil, nil end

  if reaper.GetMediaTrackInfo_Value(track, "I_FREEMODE") == 1 then
    local mouse_x, mouse_y = reaper.GetMousePosition()
    local item = reaper.GetItemFromPoint(mouse_x, mouse_y, true)
    if item and reaper.GetMediaItemTrack(item) == track then
      return item, mouse_time
    end
    return nil, nil
  end

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

-- Mode commun aux éditions sous la souris. L'action toggle gère sa durée de vie.
function PA_IsSelectedTrackMouseEditingEnabled()
  return reaper.GetExtState("PA_MouseEditing", "selected_tracks") == "1"
end

-- nil : mode désactivé, garder le comportement habituel de l'action.
-- Sinon : un item par piste (piste survolée + pistes sélectionnées), sans doublons.
-- edge="left" cherche le voisin de droite dans un trou, "right" celui de gauche.
-- Sans edge, seuls les items traversés par le temps souris sont retenus.
-- neighbors_only sert à la copie : ignorer les items traversés par la souris.
function PA_GetMouseEditTargets(time, edge, neighbors_only)
  if not PA_IsSelectedTrackMouseEditingEnabled() then return nil end

  local targets = {}
  local hovered_track = PA_GetMouseArrangeContext()
  if not hovered_track then return targets end

  -- Sans géométrie de l'arrangeur, ne pas risquer d'éditer des pistes hors écran.
  if not reaper.JS_Window_FindChildByID or not reaper.JS_Window_GetClientRect then
    return targets
  end
  local arrange = reaper.JS_Window_FindChildByID(reaper.GetMainHwnd(), 1000)
  if not arrange then return targets end
  local ok, _, top, _, bottom = reaper.JS_Window_GetClientRect(arrange)
  if not ok or bottom <= top then return targets end

  local view_start, view_end = reaper.GetSet_ArrangeView2(0, false, 0, 0)
  if time < view_start or time >= view_end then return targets end
  local _, mouse_y = reaper.GetMousePosition()
  local hovered_y = reaper.GetMediaTrackInfo_Value(hovered_track, "I_TCPY")
  local hovered_h = reaper.GetMediaTrackInfo_Value(hovered_track, "I_TCPH")
  local height_ratio = math.max(0, math.min(0.999999,
    (mouse_y - top - hovered_y) / math.max(1, hovered_h)))

  local tracks, seen = { hovered_track }, { [hovered_track] = true }
  for i = 0, reaper.CountSelectedTracks(0) - 1 do
    local track = reaper.GetSelectedTrack(0, i)
    if not seen[track] then
      seen[track] = true
      tracks[#tracks + 1] = track
    end
  end

  for _, track in ipairs(tracks) do
    local track_y = reaper.GetMediaTrackInfo_Value(track, "I_TCPY")
    local track_h = reaper.GetMediaTrackInfo_Value(track, "I_TCPH")
    if reaper.IsTrackVisible(track, false) and track_h > 0
      and track_y < bottom - top and track_y + track_h > 0 then
      local free_mode = reaper.GetMediaTrackInfo_Value(track, "I_FREEMODE") ~= 0
      local target_y = height_ratio * track_h
      local hit, neighbor, distance = nil, nil, math.huge
      for i = 0, reaper.CountTrackMediaItems(track) - 1 do
        local item = reaper.GetTrackMediaItem(track, i)
        local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local ending = pos + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        local item_y = reaper.GetMediaItemInfo_Value(item, "I_LASTY")
        local item_h = reaper.GetMediaItemInfo_Value(item, "I_LASTH")
        if pos < view_end and ending > view_start and item_h > 0
          and track_y + item_y < bottom - top and track_y + item_y + item_h > 0
          and reaper.GetMediaItemInfo_Value(item, "B_FIXEDLANE_HIDDEN") == 0
          and (math.floor(reaper.GetMediaItemInfo_Value(item, "C_LOCK")) & 1) == 0
          and (not free_mode or (target_y >= item_y and target_y < item_y + item_h)) then
          if not neighbors_only and pos <= time and ending > time then
            hit = hit or item
          elseif edge == "left" and pos >= time and pos - time < distance then
            neighbor, distance = item, pos - time
          elseif edge == "right" and ending <= time and time - ending < distance then
            neighbor, distance = item, time - ending
          end
        end
      end
      local item = hit or neighbor
      if item then targets[#targets + 1] = item end
    end
  end
  return targets
end
