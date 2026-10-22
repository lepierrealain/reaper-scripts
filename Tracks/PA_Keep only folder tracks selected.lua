-- @description Keep only folder tracks selected
-- @author lepierrealain
-- @version 1.0

-- Filters the current selection, keeping only folder parents (including nested folders).
-- Normal tracks, folder-closing tracks and the master track are deselected.

local function main()
  local count = reaper.CountSelectedTracks2(0, true)
  if count == 0 then return end

  reaper.Undo_BeginBlock()

  -- Iterate backwards because deselecting a track changes the selection indices.
  for i = count - 1, 0, -1 do
    local track = reaper.GetSelectedTrack2(0, i, true)
    if reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH") <= 0 then
      reaper.SetTrackSelected(track, false)
    end
  end

  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Keep only folder tracks selected", -1)
end

main()
