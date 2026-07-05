-- @description Insert automation item 1s before each region and at end of each region on all envelopes with points
-- @author lepierrealain
-- @version 1.2

local r = reaper

local AI_LEN = 1.0
local EPS = 1e-7

-- Collect all project regions (not markers)
local function getRegions()
  local regions = {}
  local n = r.CountProjectMarkers(0)
  for i = 0, n - 1 do
    local _, is_region, pos, rend = r.EnumProjectMarkers(i)
    if is_region then
      regions[#regions + 1] = { pos = pos, rend = rend }
    end
  end
  return regions
end

-- True if an existing automation item on env overlaps [target_pos, target_pos + len)
local function overlapsExistingItem(env, target_pos, len)
  for i = 0, r.CountAutomationItems(env) - 1 do
    local ai_pos = r.GetSetAutomationItemInfo(env, i, "D_POSITION", 0, false)
    local ai_len = r.GetSetAutomationItemInfo(env, i, "D_LENGTH", 0, false)
    if target_pos < ai_pos + ai_len - EPS and target_pos + len > ai_pos + EPS then
      return true
    end
  end
  return false
end

-- Insert a 1-second automation item at target_pos on env, avoiding overlaps.
-- pool_id: reuse an existing pool (linked copy), or nil/-1 to create a new one.
-- Returns the new item's index, or nil if nothing was inserted.
local function insertAutoItem(env, target_pos, pool_id)
  if overlapsExistingItem(env, target_pos, AI_LEN) then return nil end
  local ai_idx = r.InsertAutomationItem(env, pool_id or -1, target_pos, AI_LEN)
  if ai_idx < 0 then return nil end
  return ai_idx
end

-- True if the underlying envelope has at least one point in [reg.pos, reg.rend)
local function hasPointInRegion(env, reg)
  local pt_idx = r.GetEnvelopePointByTimeEx(env, -1, reg.rend)
  while pt_idx >= 0 do
    local _, pt_time = r.GetEnvelopePointEx(env, -1, pt_idx)
    if pt_time < reg.rend then
      return pt_time >= reg.pos
    end
    pt_idx = pt_idx - 1
  end
  return false
end

local function processEnvelope(env, regions, counter)
  local before_pool_id  -- pool ID of the first "before" item, reused for subsequent regions

  for _, reg in ipairs(regions) do
    local before = math.max(reg.pos - AI_LEN, 0)

    local ai_idx = insertAutoItem(env, before, before_pool_id)
    if ai_idx then
      counter = counter + 1
      if not before_pool_id then
        before_pool_id = r.GetSetAutomationItemInfo(env, ai_idx, "D_POOL_ID", 0, false)
      end
    end

    if hasPointInRegion(env, reg) and insertAutoItem(env, reg.rend) then
      counter = counter + 1
    end
  end
  -- InsertAutomationItem seul ne déclenche pas la réconciliation de l'enveloppe
  -- (bords non rattachés) ; le tri force le recalcul
  r.Envelope_SortPointsEx(env, -1)
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
      if r.CountEnvelopePointsEx(env, -1) > 0 then
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
            if r.CountEnvelopePointsEx(env, -1) > 0 then
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
