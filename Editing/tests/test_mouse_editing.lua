-- Run from the repository root with Lua 5.3+: lua Editing/tests/test_mouse_editing.lua
-- Exercises the actual actions with a simulated REAPER project; no user project is opened.
local ROOT = "Editing/"
local checks = 0

local function equal(actual, expected, message)
  assert(actual == expected, (message or "value") .. ": expected " .. tostring(expected)
    .. ", got " .. tostring(actual))
  checks = checks + 1
end

local function near(actual, expected, message)
  assert(math.abs(actual - expected) < 1e-9, message or "number differs")
  checks = checks + 1
end

local function fixture()
  local state = { tracks = {}, splits = {}, ext = "1", mouse_time = 10,
    mouse_y = 140, view_start = 0, view_end = 20, undo = 0, refresh = 0, guid = 0 }
  for i = 1, 8 do
    state.tracks[i] = { items = {}, I_TCPY = (i - 1) * 80, I_TCPH = 80,
      I_FREEMODE = 0, I_NUMFIXEDLANES = 0, selected = i ~= 1 and i ~= 8, visible = i ~= 6 }
  end
  state.tracks[5].I_TCPY = 600 -- selected, vertically off screen
  state.tracks[6].I_TCPY = 280 -- inside viewport but hidden in arrange
  state.tracks[7].I_TCPY = 360 -- partially visible
  state.hovered = state.tracks[1]
  function state.add(track_index, pos, length, fields)
    local track = state.tracks[track_index]
    local item = { track = track, D_POSITION = pos, D_LENGTH = length,
      D_FADEINLEN = 0.25, D_FADEOUTLEN = 0.5, I_LASTY = 0, I_LASTH = 80,
      take = { D_STARTOFFS = 5, D_PLAYRATE = 1 }, selected = false }
    for key, value in pairs(fields or {}) do item[key] = value end
    track.items[#track.items + 1] = item
    return item
  end
  state.a = state.add(1, 8, 6)
  state.b = state.add(2, 6, 9)
  state.left = state.add(3, 2, 2)
  state.right = state.add(3, 12, 3)
  state.horizontal = state.add(4, 30, 4)
  state.vertical = state.add(5, 8, 6)
  state.hidden = state.add(6, 8, 6)
  state.partial = state.add(7, 9, 9)
  state.unselected = state.add(8, 8, 6)
  -- An unrelated old item selection must not broaden the armed track mode.
  state.horizontal.selected, state.vertical.selected = true, true

  local function selected_items()
    local selected = {}
    for _, track in ipairs(state.tracks) do
      for _, item in ipairs(track.items) do
        if item.selected then selected[#selected + 1] = item end
      end
    end
    return selected
  end
  local function selected_tracks()
    local selected = {}
    for _, track in ipairs(state.tracks) do
      if track.selected then selected[#selected + 1] = track end
    end
    return selected
  end
  reaper = {
    get_action_context = function() return false, state.script_path, 0, 1234 end,
    GetExtState = function() return state.ext end,
    SetExtState = function(_, _, value, persist) state.ext = value; equal(persist, false) end,
    DeleteExtState = function() state.ext = "" end,
    SetToggleCommandState = function(_, _, value) state.toggle = value end,
    RefreshToolbar2 = function() state.toolbar_refreshed = true end,
    set_action_options = function(value) state.action_options = value end,
    atexit = function(callback) state.exit = callback end,
    defer = function(callback) state.deferred = callback end,
    ShowMessageBox = function(message) state.message = message end,
    BR_GetMouseCursorContext = function() return state.outside and "mcp" or "arrange" end,
    BR_GetMouseCursorContext_Position = function() return state.mouse_time end,
    GetMousePosition = function() return 200, state.mouse_y end,
    GetTrackFromPoint = function() return state.hovered end,
    GetMainHwnd = function() return {} end,
    JS_Window_FindChildByID = function() return {} end,
    JS_Window_GetClientRect = function() return true, 0, 100, 1000, 500 end,
    JS_Window_GetRect = function() return true, 0, 100, 1000, 500 end,
    GetSet_ArrangeView2 = function() return state.view_start, state.view_end end,
    GetMediaTrackInfo_Value = function(track, key) return track[key] or 0 end,
    GetMediaItemInfo_Value = function(item, key)
      assert(not item.deleted, "read through deleted item pointer")
      return item[key] or 0
    end,
    SetMediaItemInfo_Value = function(item, key, value)
      assert(not item.deleted, "write through deleted item pointer")
      item[key] = value; return true
    end,
    IsTrackVisible = function(track) return track.visible end,
    CountSelectedTracks = function() return #selected_tracks() end,
    GetSelectedTrack = function(_, i) return selected_tracks()[i + 1] end,
    CountTrackMediaItems = function(track) return #track.items end,
    GetTrackMediaItem = function(track, i) return track.items[i + 1] end,
    GetMediaItemTrack = function(item) return item.track end,
    CountSelectedMediaItems = function() return #selected_items() end,
    GetSelectedMediaItem = function(_, i) return selected_items()[i + 1] end,
    SelectAllMediaItems = function(_, value)
      for _, track in ipairs(state.tracks) do
        for _, item in ipairs(track.items) do item.selected = value end
      end
    end,
    SetMediaItemSelected = function(item, value) item.selected = value end,
    GetToggleCommandState = function() return state.snap and 1 or 0 end,
    SnapToGrid = function(_, time) return state.snap_time or math.floor(time + 0.5) end,
    GetActiveTake = function(item) return item.take end,
    TakeIsMIDI = function(take) return take.midi or false end,
    GetMediaItemTakeInfo_Value = function(take, key) return take[key] end,
    SetMediaItemTakeInfo_Value = function(take, key, value) take[key] = value; return true end,
    GetMediaItemTake_Source = function() return {} end,
    GetMediaSourceLength = function() return 100, false end,
    Undo_BeginBlock = function() state.undo = state.undo + 1 end,
    Undo_EndBlock = function() state.undo = state.undo - 1 end,
    PreventUIRefresh = function(delta) state.refresh = state.refresh + delta end,
    UpdateArrange = function() state.updated = true end,
    GetCursorPosition = function() return 50 end,
    SplitMediaItem = function(item, time)
      if time <= item.D_POSITION or time >= item.D_POSITION + item.D_LENGTH then return nil end
      state.splits[#state.splits + 1] = { item = item, time = time }
      return {}
    end,
    genGuid = function() state.guid = state.guid + 1; return "{NEW-" .. state.guid .. "}" end,
    GetItemStateChunk = function(item)
      return true, "<ITEM\nIGUID {OLD}\nGUID {OLD-TAKE}\nPOOLEDEVTS {KEEP-POOL}\n>"
    end,
    AddMediaItemToTrack = function(track)
      local item = { track = track }; track.items[#track.items + 1] = item; return item
    end,
    SetItemStateChunk = function(item, chunk) item.chunk = chunk; return true end,
    SetMediaItemPosition = function(item, pos) item.D_POSITION = pos; return true end,
    DeleteTrackMediaItem = function(track, item)
      for i, candidate in ipairs(track.items) do
        if candidate == item then table.remove(track.items, i); item.deleted = true; return true end
      end
      return false
    end,
  }
  function state.run(filename)
    state.script_path = ROOT .. filename
    dofile(state.script_path)
    equal(state.undo, 0, "balanced undo")
    equal(state.refresh, 0, "balanced refresh")
  end
  function state.unchanged()
    equal(state.horizontal.D_POSITION, 30, "horizontal exclusion")
    equal(state.vertical.D_POSITION, 8, "vertical exclusion")
    equal(state.hidden.D_POSITION, 8, "hidden track exclusion")
    equal(state.unselected.D_POSITION, 8, "unselected track exclusion")
  end
  dofile("Libraries/PA_lib_mouse.lua")
  return state
end

local state = fixture()
local targets = PA_GetMouseEditTargets(10, "left")
equal(#targets, 4)
equal(targets[1], state.a, "hovered track included")
equal(targets[2], state.b, "different item bounds allowed")
equal(targets[3], state.right, "nearest right neighbor")
equal(targets[4], state.partial, "partially visible track included")
state.hovered.selected = true
equal(#PA_GetMouseEditTargets(10, "left"), 4, "hovered selected track not duplicated")
local touching = state.add(4, 20, 2)
equal(#PA_GetMouseEditTargets(10, "left"), 4, "item at right viewport boundary excluded")
touching.D_POSITION, touching.D_LENGTH = -2, 2
equal(#PA_GetMouseEditTargets(10, "right"), 4, "item at left viewport boundary excluded")
state.ext = ""
equal(PA_GetMouseEditTargets(10, "left"), nil, "disabled sentinel")
state.ext = "1"
equal(#PA_GetMouseEditTargets(25, "left"), 0, "mouse outside visible time")
reaper.JS_Window_GetClientRect = nil
equal(#PA_GetMouseEditTargets(10, "left"), 0, "no viewport means no edits")

for _, filename in ipairs({ "PA_Trim left of item under mouse cursor.lua",
  "PA_Trim left of item under mouse cursor (smart).lua" }) do
  state = fixture()
  state.a.take.D_STARTOFFS = -3
  state.run(filename)
  for _, item in ipairs({ state.a, state.b, state.right, state.partial }) do
    equal(item.D_POSITION, 10, "trim left target")
    near(item.D_FADEINLEN, 0.25, "fade preserved")
  end
  equal(state.a.take.D_STARTOFFS, -1, "negative source offset preserved")
  equal(state.left.D_LENGTH, 2, "opposite neighbor untouched")
  state.unchanged()
end

state = fixture()
state.run("PA_Trim right of item under mouse cursor.lua")
for _, item in ipairs({ state.a, state.b, state.left, state.partial }) do
  equal(item.D_POSITION + item.D_LENGTH, 10, "trim right target")
end
equal(state.right.D_POSITION, 12, "opposite neighbor untouched")
state.unchanged()

state = fixture()
state.run("PA_Add fade in to item under mouse cursor.lua")
equal(state.a.D_FADEINLEN, 2)
equal(state.b.D_FADEINLEN, 4)
equal(state.right.D_FADEINLEN, 0, "clear neighbor fade in gap")
equal(state.a.D_FADEINLEN_AUTO, 0)
near(state.horizontal.D_FADEINLEN, 0.25)
state.unchanged()

state = fixture()
state.run("PA_Add fade out to item under mouse cursor.lua")
equal(state.a.D_FADEOUTLEN, 4)
equal(state.b.D_FADEOUTLEN, 5)
equal(state.left.D_FADEOUTLEN, 0, "clear neighbor fade in gap")
equal(state.a.D_FADEOUTLEN_AUTO, 0)
near(state.vertical.D_FADEOUTLEN, 0.5)

state = fixture()
state.run("PA_Split item under mouse cursor.lua")
equal(#state.splits, 3, "split only items at mouse time")
for _, split in ipairs(state.splits) do equal(split.time, 10) end
state.unchanged()

state = fixture()
state.run("PA_Set snap offset at mouse cursor.lua")
equal(state.a.D_SNAPOFFSET, 2)
equal(state.b.D_SNAPOFFSET, 4, "snap offset relative to each item")
equal(state.partial.D_SNAPOFFSET, 1)
equal(state.right.D_SNAPOFFSET, nil, "no snap offset for a neighbor")

state = fixture()
state.add(1, 1, 2)
state.add(2, 2, 3)
state.add(7, 3, 2)
state.run("PA_Copy first item to left of mouse cursor.lua")
local copy_guids = {}
for _, track_index in ipairs({ 1, 2, 3, 7 }) do
  local track = state.tracks[track_index]
  local copy = track.items[#track.items]
  equal(copy.D_POSITION, 10, "copy destination")
  equal(copy.selected, true, "all copies selected")
  assert(copy.chunk:find("POOLEDEVTS {KEEP%-POOL}"), "pool must survive copy")
  local guid = copy.chunk:match("IGUID ({[^}]+})")
  assert(not copy_guids[guid], "copy GUIDs must be unique")
  copy_guids[guid] = true
end
equal(#state.tracks[4].items, 1, "no offscreen copy")

-- Lanes and free positioning use the same relative height on every selected track.
state = fixture()
state.tracks[2].I_FREEMODE = 2
state.b.I_LASTH = 40
state.b.I_LASTY = 40
local upper = state.add(2, 7, 8, { I_LASTH = 40, I_LASTY = 0 })
state.add(2, 8, 8, { B_FIXEDLANE_HIDDEN = 1 })
targets = PA_GetMouseEditTargets(10)
equal(targets[2], state.b, "lower fixed lane at relative half height")
state.tracks[2].I_FREEMODE = 1
state.mouse_y = 120
targets = PA_GetMouseEditTargets(10)
equal(targets[2], upper, "upper free positioning item")
upper.C_LOCK = 1
equal(#PA_GetMouseEditTargets(10), 2, "locked items ignored")

-- The toolbar reflects the running toggle and cleanup disables the mode.
state = fixture()
state.run("PA_Edit visible items on selected tracks under mouse cursor (toggle).lua")
equal(state.ext, "1")
equal(state.toggle, 1)
equal(state.action_options, 1)
assert(state.deferred and state.exit and state.toolbar_refreshed)
state.exit()
equal(state.ext, "")
equal(state.toggle, 0)

state = fixture()
reaper.JS_Window_GetClientRect = nil
state.ext = ""
state.run("PA_Edit visible items on selected tracks under mouse cursor (toggle).lua")
equal(state.ext, "", "missing extension does not enable mode")
assert(state.message and not state.deferred)

-- Disabled mode keeps the old selected-item branch, including offscreen selections.
state = fixture()
state.ext = ""
state.run("PA_Trim left of item under mouse cursor (smart).lua")
equal(state.a.D_POSITION, 8)
equal(state.horizontal.D_POSITION, 25) -- extension clamped to available source
equal(state.vertical.D_POSITION, 10)

-- A pooled MIDI extension can replace a later target. The batch must use its new pointer.
state = fixture()
dofile("Libraries/PA_lib_item.lua")
local replacement = state.add(2, 6, 9)
local old_b, call_count = state.b, 0
PA_TrimItemLeft = function(item)
  call_count = call_count + 1
  if call_count == 1 then
    old_b.deleted = true
    return item, { [old_b] = replacement }
  end
  equal(item, replacement, "batch updates replaced pooled pointer")
  return item
end
PA_TrimItemsLeft({ state.a, old_b }, 10)
equal(call_count, 2)
near(replacement.D_FADEINLEN, 0.25)

print("PASS: mouse editing on selected tracks (" .. checks .. " assertions)")
