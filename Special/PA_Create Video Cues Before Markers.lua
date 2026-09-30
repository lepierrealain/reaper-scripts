-- ============================================================
-- REAPER - Generate Visual Cues Before Markers
-- ============================================================
-- Creates a dedicated track containing a 1-second
-- Video Processor item before every project marker.
--
-- Run again whenever markers have changed.
-- ============================================================

local CUE_TRACK_NAME = "VISUAL CUES"
local CUE_DURATION = 1.0

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

---------------------------------------------------------------
-- FIND / CREATE CUE TRACK
---------------------------------------------------------------

local function findTrack(name)

    for i = 0, reaper.CountTracks(0) - 1 do

        local track = reaper.GetTrack(0, i)

        local _, trackName =
            reaper.GetSetMediaTrackInfo_String(
                track,
                "P_NAME",
                "",
                false
            )

        if trackName == name then
            return track
        end
    end

    return nil
end


local cueTrack = findTrack(CUE_TRACK_NAME)

if not cueTrack then

    reaper.InsertTrackAtIndex(
        reaper.CountTracks(0),
        true
    )

    cueTrack =
        reaper.GetTrack(
            0,
            reaper.CountTracks(0) - 1
        )

    reaper.GetSetMediaTrackInfo_String(
        cueTrack,
        "P_NAME",
        CUE_TRACK_NAME,
        true
    )
end


---------------------------------------------------------------
-- DELETE OLD CUES
---------------------------------------------------------------

for i = reaper.CountTrackMediaItems(cueTrack) - 1, 0, -1 do

    local item =
        reaper.GetTrackMediaItem(
            cueTrack,
            i
        )

    reaper.DeleteTrackMediaItem(
        cueTrack,
        item
    )
end


---------------------------------------------------------------
-- CREATE CUE ITEM
---------------------------------------------------------------

local function createCue(markerPos, markerName)

    local startPos =
        math.max(
            0,
            markerPos - CUE_DURATION
        )

    local duration =
        markerPos - startPos

    if duration <= 0 then
        return
    end


    -----------------------------------------------------------
    -- Create item
    -----------------------------------------------------------

    local item =
        reaper.AddMediaItemToTrack(
            cueTrack
        )

    reaper.SetMediaItemInfo_Value(
        item,
        "D_POSITION",
        startPos
    )

    reaper.SetMediaItemInfo_Value(
        item,
        "D_LENGTH",
        duration
    )


    -----------------------------------------------------------
    -- Create take
    -----------------------------------------------------------

    local take =
        reaper.AddTakeToMediaItem(
            item
        )

    reaper.GetSetMediaItemTakeInfo_String(
        take,
        "P_NAME",
        "SYNC → " .. markerName,
        true
    )


    -----------------------------------------------------------
    -- Add VIDEO PROCESSOR source
    -----------------------------------------------------------

    local source =
        reaper.PCM_Source_CreateFromType(
            "VIDEOEFFECT"
        )

    if source then

        reaper.SetMediaItemTake_Source(
            take,
            source
        )

    end

end


---------------------------------------------------------------
-- ENUMERATE MARKERS
---------------------------------------------------------------

local _, numMarkers, numRegions =
    reaper.CountProjectMarkers(0)

local total =
    numMarkers + numRegions

local created = 0


for i = 0, total - 1 do

    local retval,
          isRegion,
          position,
          regionEnd,
          name,
          markerIndex =
          reaper.EnumProjectMarkers(i)


    if retval > 0 and not isRegion then

        if name == "" then
            name = "Marker " .. markerIndex
        end

        createCue(
            position,
            name
        )

        created =
            created + 1
    end
end


---------------------------------------------------------------
-- FINISH
---------------------------------------------------------------

reaper.PreventUIRefresh(-1)

reaper.UpdateArrange()

reaper.Undo_EndBlock(
    "Generate visual cues before markers",
    -1
)


reaper.ShowMessageBox(
    created ..
    " cue(s) généré(s).\n\n" ..
    "Chaque cue commence 1 seconde avant son marker.",
    "Visual Cues",
    0
)
