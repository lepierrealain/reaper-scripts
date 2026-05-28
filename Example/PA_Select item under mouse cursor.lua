-- @description Select item under mouse cursor
-- @author lepierrealain
-- @version 1.0

-- Vérifie que js_ReaScriptAPI est disponible
if not reaper.JS_Window_FromPoint then
  reaper.MB("js_ReaScriptAPI est requis mais non trouvé.\nInstalle-le via ReaPack.", "Erreur", 0)
  return
end

-- 1. Position souris en coordonnées écran
local mouse_x, mouse_y = reaper.GetMousePosition()

-- 2. Piste sous la souris (coordonnées écran directes, pas besoin de conversion)
local track, context = reaper.GetTrackFromPoint(mouse_x, mouse_y)

if not track then
  -- La souris n'est pas sur une piste
  return
end

-- On ignore le contexte TCP (panneau de contrôle) : context & 1 = TCP, context & 2 = MCP
-- On veut uniquement l'arrangeur (contexte 0 ou flag absent)
if context and (context & 1 ~= 0 or context & 2 ~= 0) then
  return
end

-- 3. Convertir la position X souris (écran) en position temporelle
-- On passe des positions en pixels à GetSet_ArrangeView2 pour qu'il nous retourne
-- les temps correspondants — ce qui évite tout problème lié à la largeur du TCP.
local arrange_hwnd = reaper.JS_Window_FindChildByID(reaper.GetMainHwnd(), 1000)
if not arrange_hwnd then return end

-- Coordonnées client de la souris dans la fenêtre arrangeur (origine = bord gauche du TCP)
local client_x, _ = reaper.JS_Window_ScreenToClient(arrange_hwnd, mouse_x, mouse_y)

-- GetSet_ArrangeView2 avec scroll_x en pixels : retourne start/end en secondes pour ces pixels
-- On demande la conversion du pixel client_x et client_x+1 pour obtenir le temps exact
local mouse_time, _ = reaper.GetSet_ArrangeView2(0, false, client_x, client_x + 1)

if not mouse_time then return end

-- 4. Chercher l'item sur cette piste qui contient mouse_time
local found_item = nil
local num_items = reaper.CountTrackMediaItems(track)

for i = 0, num_items - 1 do
  local item = reaper.GetTrackMediaItem(track, i)
  local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_len   = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local item_end   = item_start + item_len

  if mouse_time >= item_start and mouse_time <= item_end then
    found_item = item
    break
  end
end

if not found_item then
  -- Aucun item sous la souris
  return
end

-- 5. Désélectionner tout, puis sélectionner l'item trouvé
reaper.PreventUIRefresh(1)
reaper.SelectAllMediaItems(0, false)
reaper.SetMediaItemSelected(found_item, true)
reaper.PreventUIRefresh(-1)

-- Mettre à jour l'affichage
reaper.UpdateArrange()
