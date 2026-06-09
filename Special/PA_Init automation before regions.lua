-- @description Insert automation item 1s before each region and at end of each region on all envelopes with points
-- @author lepierrealain
-- @version 1.1

local r = reaper

-- Collect all project regions (not markers)
local function getRegions()
  local regions = {}
  local n = r.CountProjectMarkers(0)
  for i = 0, n - 1 do
    local _, is_region, pos, rend, _, idx = r.EnumProjectMarkers(i)
    if is_region then
      regions[#regions + 1] = { pos = pos, rend = rend, idx = idx }
    end
  end
  return regions
end

-- Check if an envelope has at least one automation point
local function envelopeHasPoints(env)
  return r.CountEnvelopePoints(env) > 0
end

-- Insert a 1-second automation item at target_pos on env, avoiding duplicates.
-- Returns true if an item was actually inserted.
local function insertAutoItem(env, target_pos)
  local ai_count = r.CountAutomationItems(env)
  for i = 0, ai_count - 1 do
    local ai_pos = r.GetSetAutomationItemInfo(env, i, "D_POSITION", 0, false)
    local ai_len = r.GetSetAutomationItemInfo(env, i, "D_LENGTH", 0, false)
    if math.abs(ai_pos - target_pos) < 1e-7 then return false end
    if target_pos >= ai_pos and target_pos < ai_pos + ai_len then return false end
  end
  local ai_idx = r.InsertAutomationItem(env, -1, target_pos, 1.0)
  if ai_idx < 0 then return false end
  return true
end

local function processEnvelope(env, regions, counter)
  local before_pool_id = nil  -- pool ID of the first "before" item, reused for subsequent regions

  for _, reg in ipairs(regions) do
    local before = reg.pos - 1.0
    if before < 0 then before = 0 end

    if before_pool_id then
      -- Reuse the pool from region 1 (linked copy)
      local ai_idx = r.InsertAutomationItem(env, before_pool_id, before, 1.0)
      if ai_idx >= 0 then counter = counter + 1 end
    else
      if insertAutoItem(env, before) then
        counter = counter + 1
        local ai_idx = r.CountAutomationItems(env) - 1
        before_pool_id = r.GetSetAutomationItemInfo(env, ai_idx, "D_POOL_ID", 0, false)
      end
    end

    -- Check if the envelope has at least one point inside the region
    local has_point_in_region = false
    local pt_count = r.CountEnvelopePointsEx(env, -1)
    for p = 0, pt_count - 1 do
      local _, pt_time = r.GetEnvelopePointEx(env, -1, p)
      if pt_time >= reg.pos and pt_time < reg.rend then
        has_point_in_region = true
        break
      end
    end

    if has_point_in_region and insertAutoItem(env, reg.rend) then
      counter = counter + 1
    end
  end
  return counter
end

local function main()
  local regions = getRegions()
  if #regions == 0 then
    r.ShowMessageBox("Aucune région trouvée dans le projet.", "Init automation before regions", 0)
    return
  end

  local inserted = 0

  r.PreventUIRefresh(1)
  r.Undo_BeginBlock()

  local num_tracks = r.CountTracks(0)
  for t = 0, num_tracks - 1 do
    local track = r.GetTrack(0, t)
    for e = 0, r.CountTrackEnvelopes(track) - 1 do
      local env = r.GetTrackEnvelope(track, e)
      if envelopeHasPoints(env) then
        inserted = processEnvelope(env, regions, inserted)
      end
    end
    for i = 0, r.GetTrackNumMediaItems(track) - 1 do
      local item = r.GetTrackMediaItem(track, i)
      for tk = 0, r.CountTakes(item) - 1 do
        local take = r.GetTake(item, tk)
        if take then
          for e = 0, r.CountTakeEnvelopes(take) - 1 do
            local env = r.GetTakeEnvelope(take, e)
            if envelopeHasPoints(env) then
              inserted = processEnvelope(env, regions, inserted)
            end
          end
        end
      end
    end
  end

  r.Undo_EndBlock("Insert automation items before and after regions", -1)
  r.PreventUIRefresh(-1)
  r.UpdateArrange()

end

main()
