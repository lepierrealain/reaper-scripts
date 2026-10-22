-- @description Copy first item to left of mouse cursor
-- @author lepierrealain
-- @version 1.0
-- @about
--   Copie l'item le plus proche entierement a gauche sur la piste survolee.
--   Le debut de la copie est place sous la souris (grille si snap actif).
--   Respecte la lane survolee et la hauteur en free item positioning.
--   Necessite SWS ; js_ReaScriptAPI pour les lanes et le free positioning.

local lib_path = ({ reaper.get_action_context() })[2]:match("^(.+[\\/])")
local lib_root = lib_path .. ".." .. package.config:sub(1,1) .. "Libraries" .. package.config:sub(1,1)
dofile(lib_root .. "PA_lib_mouse.lua")

local function get_first_item_to_left(track, time, lane)
  local closest, closest_end, closest_start = nil, -math.huge, -math.huge
  for i = 0, reaper.CountTrackMediaItems(track) - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_end = item_start + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    if item_end <= time
      and (item_end > closest_end or (item_end == closest_end and item_start > closest_start))
      and (lane == nil or math.floor(reaper.GetMediaItemInfo_Value(item, "I_FIXEDLANE")) == lane)
      and PA_IsItemAtMouseHeight(track, item) then
      closest, closest_end, closest_start = item, item_end, item_start
    end
  end
  return closest
end

local function main()
  if not reaper.BR_GetMouseCursorContext or not reaper.BR_GetMouseCursorContext_Position then
    reaper.ShowMessageBox("Ce script necessite l'extension SWS.", "Copy first item to left of mouse cursor", 0)
    return
  end

  local track, mouse_time = PA_GetMouseArrangeContext()
  if not track or not mouse_time or mouse_time < 0 then return end

  local needs_js = reaper.GetMediaTrackInfo_Value(track, "I_NUMFIXEDLANES") > 1
    or reaper.GetMediaTrackInfo_Value(track, "I_FREEMODE") == 1
  if needs_js and (not reaper.JS_Window_FindChildByID or not reaper.JS_Window_GetRect) then
    reaper.ShowMessageBox("Les lanes et le free item positioning necessitent js_ReaScriptAPI.",
      "Copy first item to left of mouse cursor", 0)
    return
  end

  local sources = PA_GetMouseEditTargets(mouse_time, "right", true)
  if not sources then
    local source = get_first_item_to_left(track, mouse_time, PA_GetHoveredFixedLane(track))
    sources = source and { source } or {}
  end
  if #sources == 0 then return end

  local copies = {}
  for _, source in ipairs(sources) do
    local ok, chunk = reaper.GetItemStateChunk(source, "", false)
    if ok then
      -- Identifiants propres a la copie, sans changer le pool MIDI eventuel.
      for _, key in ipairs({ "IGUID", "GUID", "FXID", "EGUID" }) do
        chunk = chunk:gsub("(\n[ \t]*" .. key .. "[ \t]+){[^}\r\n]+}", function(prefix)
          return prefix .. reaper.genGuid("")
        end)
      end
      copies[#copies + 1] = { track = reaper.GetMediaItemTrack(source), chunk = chunk }
    end
  end
  if #copies == 0 then return end

  local dest_pos = mouse_time
  if reaper.GetToggleCommandState(1157) == 1 then
    dest_pos = reaper.SnapToGrid(0, dest_pos)
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local selection_cleared = false
  for _, data in ipairs(copies) do
    local copy = reaper.AddMediaItemToTrack(data.track)
    if copy then
      local success = reaper.SetItemStateChunk(copy, data.chunk, false)
      if success then success = reaper.SetMediaItemPosition(copy, dest_pos, false) end
      if success then
        if not selection_cleared then
          reaper.SelectAllMediaItems(0, false)
          selection_cleared = true
        end
        reaper.SetMediaItemSelected(copy, true)
      else
        reaper.DeleteTrackMediaItem(data.track, copy)
      end
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Copy first item to left of mouse cursor", -1)
end

main()
