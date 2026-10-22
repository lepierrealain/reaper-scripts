-- @description Select all child folder tracks (keep current selection)
-- @author lepierrealain
-- @version 1.0

-- Adds all descendant folder parents of the selected tracks, including nested folders.
-- The original selection is preserved, even when it includes normal tracks.

local function main()
  local count = reaper.CountSelectedTracks(0)
  if count == 0 then return end

  -- Snapshot the original selection before adding any descendants.
  local sources = {}
  for i = 0, count - 1 do
    sources[#sources + 1] = reaper.GetSelectedTrack(0, i)
  end

  local descendants = {}
  local track_count = reaper.CountTracks(0)
  for _, source in ipairs(sources) do
    local depth = reaper.GetMediaTrackInfo_Value(source, "I_FOLDERDEPTH")
    if depth > 0 then
      -- IP_TRACKNUMBER is 1-based, so it is also the next track's 0-based index.
      local next_index = reaper.GetMediaTrackInfo_Value(source, "IP_TRACKNUMBER")
      for i = next_index, track_count - 1 do
        local track = reaper.GetTrack(0, i)
        local folder_depth = reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH")
        if folder_depth > 0 then
          descendants[track] = true
        end
        depth = depth + folder_depth
        if depth <= 0 then break end
      end
    end
  end

  if next(descendants) == nil then return end

  reaper.Undo_BeginBlock()
  for track in pairs(descendants) do
    reaper.SetTrackSelected(track, true)
  end
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Select all child folder tracks", -1)
end

main()
