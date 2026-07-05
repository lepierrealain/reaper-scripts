-- @description Cut item under mouse cursor and next ones and remove Temp track if needed
-- @author lepierrealain
-- @version 1.0

local lib_path = ({ reaper.get_action_context() })[2]:match("^(.+[\\/])")
local lib_root = lib_path .. ".." .. package.config:sub(1,1) .. "Libraries" .. package.config:sub(1,1)
dofile(lib_root .. "PA_lib_mouse.lua")

local TEMP_NAME = "Temp muted"

-- Supprime `track` si c'est une piste "Temp muted" vide.
-- La piste juste au-dessus récupère les fermetures de folder éventuelles.
local function removeTempTrackIfEmpty(track)
  local _, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
  if name ~= TEMP_NAME or reaper.CountTrackMediaItems(track) > 0 then return end

  local idx = math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")) - 1  -- 1-based → 0-based
  local depth = math.floor(reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH"))
  if depth < 0 and idx > 0 then
    -- La piste ferme un ou plusieurs folders : reporter la fermeture au-dessus
    -- (si la piste au-dessus est le parent ouvert pour elle, il redevient une piste normale)
    local above = reaper.GetTrack(0, idx - 1)
    local above_depth = math.floor(reaper.GetMediaTrackInfo_Value(above, "I_FOLDERDEPTH"))
    reaper.SetMediaTrackInfo_Value(above, "I_FOLDERDEPTH", above_depth + depth)
  end
  reaper.DeleteTrack(track)
end

local function main()
  local item = PA_GetItemUnderMouse()
  if not item then return end

  local track = reaper.GetMediaItem_Track(item)

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  reaper.SelectAllMediaItems(0, false)
  for i = 0, reaper.CountTrackMediaItems(track) - 1 do
    local it = reaper.GetTrackMediaItem(track, i)
    if reaper.GetMediaItemInfo_Value(it, "D_POSITION") >= item_start then
      reaper.SetMediaItemSelected(it, true)
    end
  end

  reaper.Main_OnCommand(40699, 0)  -- Edit: Cut items

  removeTempTrackIfEmpty(track)

  reaper.PreventUIRefresh(-1)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Cut item under mouse cursor and next ones and remove Temp track if needed", -1)
end

main()
