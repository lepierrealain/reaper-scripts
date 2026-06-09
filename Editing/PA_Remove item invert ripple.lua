-- @description Remove item (invert ripple state)
-- @author lepierrealain
-- @version 1.0

local function getRipple()
  return reaper.SNM_GetIntConfigVar("projripedit", 0)
end

local function setRipple(mode)
  reaper.SNM_SetIntConfigVar("projripedit", mode)
end

local function main()
  local saved = getRipple()
  local inverted = (saved == 0) and 1 or 0

  setRipple(inverted)
  reaper.Main_OnCommand(reaper.NamedCommandLookup("_SWS_AWBUSDELETE"), 0)
  setRipple(saved)
end

main()
