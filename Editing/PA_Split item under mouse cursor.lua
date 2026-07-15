-- @description Split item under mouse cursor
-- @author lepierrealain
-- @version 1.0

local lib_path = ({ reaper.get_action_context() })[2]:match("^(.+[\\/])")
local lib_root = lib_path .. ".." .. package.config:sub(1,1) .. "Libraries" .. package.config:sub(1,1)
dofile(lib_root .. "PA_lib_mouse.lua")
dofile(lib_root .. "PA_lib_item.lua")

local function snap(time)
  local snap_enabled = reaper.GetToggleCommandState(1157) == 1
  return snap_enabled and reaper.SnapToGrid(0, time) or time
end

-- Souris hors arrangeur : split des items sélectionnés à l'edit cursor.
-- La partie droite de chaque item splitté reste sélectionnée.
local function SplitSelectionAtEditCursor()
  local split_time = snap(reaper.GetCursorPosition())

  local targets = {}
  for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
    targets[#targets + 1] = reaper.GetSelectedMediaItem(0, i)
  end
  if #targets == 0 then return end

  reaper.Undo_BeginBlock()
  reaper.SelectAllMediaItems(0, false)
  for _, item in ipairs(targets) do
    local right = reaper.SplitMediaItem(item, split_time)
    if right then reaper.SetMediaItemSelected(right, true) end
  end
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Split selected items at edit cursor", -1)
end

local function main()
  local item, mouse_time = PA_GetItemUnderMouse()
  if not item then
    SplitSelectionAtEditCursor()
    return
  end

  local split_time = snap(mouse_time)

  -- Items groupés à même position + tous les items sélectionnés, sans doublons
  local seen    = { [item] = true }
  local targets = {}
  for _, ti in ipairs(PA_GetRelatedItemsAtSamePosition(item)) do
    if not seen[ti] then seen[ti] = true; table.insert(targets, ti) end
  end
  for _, ti in ipairs(PA_GetAllSelectedItems(item)) do
    if not seen[ti] then seen[ti] = true; table.insert(targets, ti) end
  end

  reaper.Undo_BeginBlock()
  reaper.SelectAllMediaItems(0, false)
  reaper.SplitMediaItem(item, split_time)
  for _, ti in ipairs(targets) do
    reaper.SplitMediaItem(ti, split_time)
  end
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Split item under mouse cursor", -1)
end

main()
