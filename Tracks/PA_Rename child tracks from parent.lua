-- @description Rename selected child tracks from parent (numbered)
-- @author lepierrealain
-- @version 1.1

-- Renomme uniquement les pistes enfants selectionnees qui ne sont pas des dossiers :
-- Foley -> Foley 01, Foley 02, etc., dans l'ordre des pistes du projet.
-- Chaque parent immediat a sa propre numerotation, y compris les sous-dossiers.
-- Seules les pistes selectionnees sont comptees dans la numerotation.
-- Les pistes sans parent et les enfants d'un parent sans nom sont ignores.

local function main()
  local counters, changes = {}, {}

  for i = 0, reaper.CountSelectedTracks(0) - 1 do
    local track = reaper.GetSelectedTrack(0, i)
    if reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH") <= 0 then
      local parent = reaper.GetParentTrack(track)
      if parent then
        local _, parent_name = reaper.GetSetMediaTrackInfo_String(
          parent, "P_NAME", "", false)
        if parent_name:find("%S") then
          counters[parent] = (counters[parent] or 0) + 1
          local name = string.format("%s %02d", parent_name, counters[parent])
          local _, current_name = reaper.GetSetMediaTrackInfo_String(
            track, "P_NAME", "", false)
          if current_name ~= name then
            changes[#changes + 1] = {track = track, name = name}
          end
        end
      end
    end
  end

  if #changes == 0 then return end

  reaper.Undo_BeginBlock()
  for _, change in ipairs(changes) do
    reaper.GetSetMediaTrackInfo_String(change.track, "P_NAME", change.name, true)
  end
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Rename selected child tracks from parent", -1)
end

main()
