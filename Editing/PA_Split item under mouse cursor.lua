-- @description Split item under mouse cursor
-- @author lepierrealain
-- @version 1.0

local function main()

  -- 1. Récupérer le contexte de la souris (position en temps + infos)
  local window, segment, details = reaper.BR_GetMouseCursorContext()

  -- On vérifie qu'on est bien dans l'arrangeur (Arrange) sur un item ou du vide
  if window ~= "arrange" then
    reaper.ShowMessageBox(
      "Placez votre souris dans l'arrangeur (Arrange view).",
      "Split Item at Mouse", 0
    )
    return
  end

  -- 2. Récupérer le temps précis sous la souris
  local mouse_time = reaper.BR_GetMouseCursorContext_Position()
  if not mouse_time then
    reaper.ShowMessageBox(
      "Impossible de récupérer la position temporelle de la souris.",
      "Split Item at Mouse", 0
    )
    return
  end

  -- 3. Récupérer les coordonnées écran de la souris
  local mouse_x, mouse_y = reaper.GetMousePosition()

  -- 4. Récupérer la track sous la souris via GetTrackFromPoint
  --    GetTrackFromPoint attend des coordonnées en pixels dans la fenêtre REAPER
  local track = reaper.GetTrackFromPoint(mouse_x, mouse_y)

  if not track then
    reaper.ShowMessageBox(
      "Aucune track détectée sous la souris.\nAssurez-vous que la souris est sur une track.",
      "Split Item at Mouse", 0
    )
    return
  end

  -- 5. Parcourir les items de la track pour trouver celui(eux) sous la souris au bon moment
  local num_items = reaper.CountTrackMediaItems(track)
  local split_done = false

  reaper.Undo_BeginBlock()

  for i = 0, num_items - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_len   = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local item_end   = item_start + item_len

    -- Le curseur souris est-il à l'intérieur de cet item ?
    -- On exclut les bords exacts pour éviter une coupe sans effet
    if mouse_time > item_start and mouse_time < item_end then
      local new_item = reaper.SplitMediaItem(item, mouse_time)
      if new_item then
        split_done = true
      end
      -- On s'arrête après le premier item trouvé sur cette track
      -- (il ne peut y avoir qu'un item non-superposé à ce point en mode normal)
      break
    end
  end

  reaper.Undo_EndBlock("Split item at mouse position", -1)

  if not split_done then
    reaper.ShowMessageBox(
      "Aucun item trouvé à la position de la souris sur cette track.\n"
      .. string.format("Position souris : %.4f s", mouse_time),
      "Split Item at Mouse", 0
    )
  end

  reaper.UpdateArrange()
end

main()
