-- @description Track volume under mouse (move mouse to adjust)
-- @author lepierrealain
-- @version 1.9
-- @provides [main] .
-- @requires js_ReaScriptAPI, ReaImGui

local lib_path = ({ reaper.get_action_context() })[2]:match("^(.+[\\/])")
local lib_root = lib_path .. ".." .. package.config:sub(1,1) .. "Libraries" .. package.config:sub(1,1)
dofile(lib_root .. "PA_lib_mouse.lua")

local ctx       = reaper.ImGui_CreateContext("PA_TrackVolume")
local font      = reaper.ImGui_CreateFont("sans-serif", 14)
-- This ReaImGui build's CreateFont takes 2 args only; bold comes from the family name.
local font_bold = reaper.ImGui_CreateFont("sans-serif bold", 20)
reaper.ImGui_Attach(ctx, font)
reaper.ImGui_Attach(ctx, font_bold)

local COL_UP   = 0xFF5555FF  -- red: louder than start
local COL_DOWN = 0x55AAFFFF  -- blue: quieter than start

local mx0, my0 = reaper.GetMousePosition()
local track    = reaper.GetTrackFromPoint(mx0, my0)

if not track then
  reaper.ShowMessageBox("No track under mouse cursor.", "Track Volume", 0)
  return
end

local ret, name  = reaper.GetTrackName(track)
local track_name = ret and name or "Track"
local init_vol   = reaper.GetMediaTrackInfo_Value(track, "D_VOL")

-- dB per pixel of mouse travel
local SENSITIVITY = 0.02
-- Below this the track is treated as silent; REAPER's own faders bottom out near here.
local DB_FLOOR    = -150.0

local prev_y   = my0
local prev_btn = reaper.JS_Mouse_GetState(0x07)

reaper.Undo_BeginBlock()

local function to_db(vol)
  if vol <= 0 then return nil end
  return 20 * math.log(vol, 10)
end

local function from_db(db)
  if db <= DB_FLOOR then return 0 end
  return 10 ^ (db / 20)
end

local function fmt_db(db)
  if not db then return "-inf" end
  return string.format("%.1f", db)
end

local init_db = to_db(init_vol)
-- Volume is tracked in dB so mouse travel maps to a constant dB step at any level.
-- A track starting at silence would have no dB to move from, so start it at the floor.
local cur_db  = init_db or DB_FLOOR

-- Knob sweep. The dial shows the delta: straight up is 0, full right is +12 dB,
-- full left is -12. Volume itself stays unclamped, so past +/-12 the pointer parks
-- at an end.
local KNOB_R      = 22
local DELTA_RANGE = 12.0
local ANGLE_MIN   = math.pi * 0.75
local ANGLE_MAX   = math.pi * 2.25
local ANGLE_MID   = (ANGLE_MIN + ANGLE_MAX) * 0.5  -- 1.5*pi == 12 o'clock

local function delta_to_angle(delta)
  if not delta then return ANGLE_MIN end
  local t = math.max(-1, math.min(1, delta / DELTA_RANGE))
  return ANGLE_MID + t * (ANGLE_MAX - ANGLE_MID)
end

local function draw_knob(dl, cx, cy, radius, angle, col_arc)
  local track_w   = 3.0
  local segments  = 32

  reaper.ImGui_DrawList_AddCircleFilled(dl, cx, cy, radius, 0x444444FF)
  reaper.ImGui_DrawList_AddCircle(dl, cx, cy, radius, 0x66666688, segments, 1.5)

  -- Unfilled groove across the full sweep.
  local px, py
  for i = 0, segments do
    local a = ANGLE_MIN + (i / segments) * (ANGLE_MAX - ANGLE_MIN)
    local x = cx + math.cos(a) * (radius - track_w * 0.5)
    local y = cy + math.sin(a) * (radius - track_w * 0.5)
    if i > 0 then reaper.ImGui_DrawList_AddLine(dl, px, py, x, y, 0x888888FF, track_w) end
    px, py = x, y
  end

  -- Filled arc from 12 o'clock (delta 0) to the current position.
  local lo, hi = ANGLE_MID, angle
  if lo > hi then lo, hi = hi, lo end
  px, py = nil, nil
  for i = 0, segments do
    local a = ANGLE_MIN + (i / segments) * (ANGLE_MAX - ANGLE_MIN)
    if a >= lo and a <= hi then
      local x = cx + math.cos(a) * (radius - track_w * 0.5)
      local y = cy + math.sin(a) * (radius - track_w * 0.5)
      if px then reaper.ImGui_DrawList_AddLine(dl, px, py, x, y, col_arc, track_w) end
      px, py = x, y
    else
      px, py = nil, nil
    end
  end

  local x0 = cx + math.cos(angle) * (radius * 0.30)
  local y0 = cy + math.sin(angle) * (radius * 0.30)
  local x1 = cx + math.cos(angle) * (radius * 0.78)
  local y1 = cy + math.sin(angle) * (radius * 0.78)
  reaper.ImGui_DrawList_AddLine(dl, x0, y0, x1, y1, 0xEEEEEEFF, 2.5)
  reaper.ImGui_DrawList_AddCircleFilled(dl, cx, cy, 2.5, 0xAAAAAAFF)
end

local function close(cancel)
  if cancel then
    reaper.SetMediaTrackInfo_Value(track, "D_VOL", init_vol)
    reaper.Undo_EndBlock("Track volume (cancelled)", -1)
  else
    reaper.Undo_EndBlock("Track volume: " .. track_name, -1)
  end
end

local win_h

local function loop()
  local cur_btn = reaper.JS_Mouse_GetState(0x07)
  local clicked = (cur_btn ~= 0) and (prev_btn == 0)
  prev_btn = cur_btn

  reaper.ImGui_PushFont(ctx, font, 14)
  reaper.ImGui_PushStyleVar(ctx,   reaper.ImGui_StyleVar_WindowPadding(),  10, 8)
  reaper.ImGui_PushStyleVar(ctx,   reaper.ImGui_StyleVar_WindowRounding(), 6)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), 0x1E1E1EEE)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),     0xEEEEEEFF)

  -- Sit half a window height above the anchor. Auto-resize only reports the height
  -- after a frame, so hold the window offscreen until it's known to avoid a jump.
  if win_h then
    reaper.ImGui_SetNextWindowPos(ctx, mx0 + 16, my0 - 8 - win_h * 0.5)
  else
    reaper.ImGui_SetNextWindowPos(ctx, -10000, -10000)
  end

  local visible, open = reaper.ImGui_Begin(ctx, "##trackvol",
    true,
    reaper.ImGui_WindowFlags_NoCollapse()        |
    reaper.ImGui_WindowFlags_NoTitleBar()        |
    reaper.ImGui_WindowFlags_NoResize()          |
    reaper.ImGui_WindowFlags_NoNav()             |
    reaper.ImGui_WindowFlags_NoMove()            |
    reaper.ImGui_WindowFlags_NoScrollbar()       |
    reaper.ImGui_WindowFlags_AlwaysAutoResize()
  )

  local escaped   = reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape())
  local confirmed = reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter()) or
                    reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_KeypadEnter()) or
                    reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_V())

  if confirmed or clicked then
    open = false
    close(false)
  elseif escaped then
    open = false
    close(true)
  end

  if visible then
    local mx, my = reaper.GetMousePosition()
    local dy = prev_y - my
    prev_y = my

    if dy ~= 0 and open then
      cur_db = math.max(DB_FLOOR, cur_db + dy * SENSITIVITY)
      reaper.SetMediaTrackInfo_Value(track, "D_VOL", from_db(cur_db))
    end

    local vol_db = (cur_db > DB_FLOOR) and cur_db or nil
    local delta  = (vol_db and init_db) and (vol_db - init_db) or nil
    local delta_str
    if not delta then
      delta_str = "-inf"
    elseif delta >= 0 then
      delta_str = string.format("+%.1f", delta)
    else
      delta_str = string.format("%.1f", delta)
    end

    local delta_col
    if not delta then
      delta_col = COL_DOWN  -- silence: always a decrease from any audible start
    elseif delta == 0 then
      delta_col = 0xEEEEEEFF
    elseif delta > 0 then
      delta_col = COL_UP
    else
      delta_col = COL_DOWN
    end

    -- Knob on the left, text block on the right.
    local dl     = reaper.ImGui_GetWindowDrawList(ctx)
    local sx, sy = reaper.ImGui_GetCursorScreenPos(ctx)
    -- Two 14px lines plus the 20px delta line, with spacing between.
    local line_h = reaper.ImGui_GetTextLineHeightWithSpacing(ctx)
    local text_h = line_h * 2 + 20 + (line_h - 14)
    local knob_d = KNOB_R * 2
    -- Center the dial against the text block, whichever is shorter.
    local knob_y = sy + math.max(0, (text_h - knob_d) * 0.5)
    draw_knob(dl, sx + KNOB_R, knob_y + KNOB_R, KNOB_R, delta_to_angle(delta), delta_col)
    -- Reserve the drawn area: DrawList output doesn't advance the ImGui cursor.
    reaper.ImGui_Dummy(ctx, knob_d, math.max(knob_d, text_h))

    reaper.ImGui_SameLine(ctx, 0, 10)
    reaper.ImGui_BeginGroup(ctx)
    reaper.ImGui_TextDisabled(ctx, track_name)
    reaper.ImGui_PushFont(ctx, font_bold, 20)
    reaper.ImGui_TextColored(ctx, delta_col, delta_str .. " dB")
    reaper.ImGui_PopFont(ctx)
    reaper.ImGui_TextDisabled(ctx, fmt_db(vol_db) .. " dB")
    reaper.ImGui_EndGroup(ctx)

    local _, h = reaper.ImGui_GetWindowSize(ctx)
    win_h = h

    reaper.ImGui_End(ctx)
  end

  reaper.ImGui_PopStyleColor(ctx, 2)
  reaper.ImGui_PopStyleVar(ctx, 2)
  reaper.ImGui_PopFont(ctx)

  if open then reaper.defer(loop) end
end

reaper.defer(loop)
