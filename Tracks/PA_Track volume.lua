-- @description Track volume under mouse (move mouse to adjust)
-- @author lepierrealain
-- @version 1.5
-- @provides [main] .
-- @requires js_ReaScriptAPI, ReaImGui

local lib_path = ({ reaper.get_action_context() })[2]:match("^(.+[\\/])")
local lib_root = lib_path .. ".." .. package.config:sub(1,1) .. "Libraries" .. package.config:sub(1,1)
dofile(lib_root .. "PA_lib_mouse.lua")

local ctx  = reaper.ImGui_CreateContext("PA_TrackVolume")
local font = reaper.ImGui_CreateFont("sans-serif", 14)
reaper.ImGui_Attach(ctx, font)

local mx0, my0 = reaper.GetMousePosition()
local track    = reaper.GetTrackFromPoint(mx0, my0)

if not track then
  reaper.ShowMessageBox("No track under mouse cursor.", "Track Volume", 0)
  return
end

local ret, name  = reaper.GetTrackName(track)
local track_name = ret and name or "Track"
local init_vol   = reaper.GetMediaTrackInfo_Value(track, "D_VOL")
local prev_y     = my0
local WIN_W, WIN_H = 160, 230
local SENSITIVITY  = 0.005

local DELTA_RANGE = 12.0
local ANGLE_MIN   = math.pi * 0.75
local ANGLE_MAX   = math.pi * 2.25
local ANGLE_MID   = (ANGLE_MIN + ANGLE_MAX) * 0.5

local prev_btn = reaper.JS_Mouse_GetState(0x07)

reaper.Undo_BeginBlock()

local function to_db(vol)
  if vol <= 0 then return nil end
  return 20 * math.log(vol, 10)
end

local function fmt_db(db)
  if not db then return "-inf" end
  return string.format("%.1f", db)
end

local function delta_to_angle(delta)
  if not delta then return ANGLE_MIN end
  local t = math.max(-1, math.min(1, delta / DELTA_RANGE))
  return ANGLE_MID + t * (ANGLE_MAX - ANGLE_MID)
end

local function draw_knob(draw_list, cx, cy, radius, angle, delta)
  local track_w   = 4.0
  local pointer_w = 3.0
  local col_track = 0x888888FF
  local col_arc   = (delta and delta ~= 0) and (delta > 0 and 0xFF8844FF or 0x44AAFFFF) or 0x555555FF
  local col_ptr   = 0xEEEEEEFF

  reaper.ImGui_DrawList_AddCircleFilled(draw_list, cx, cy, radius, 0x444444FF)
  reaper.ImGui_DrawList_AddCircle(draw_list, cx, cy, radius, 0x66666688, 48, 1.5)

  local segments = 48
  local prev_x, prev_y_p
  for i = 0, segments do
    local t = i / segments
    local a = ANGLE_MIN + t * (ANGLE_MAX - ANGLE_MIN)
    local x = cx + math.cos(a) * (radius - track_w * 0.5)
    local y = cy + math.sin(a) * (radius - track_w * 0.5)
    if i > 0 then
      reaper.ImGui_DrawList_AddLine(draw_list, prev_x, prev_y_p, x, y, col_track, track_w)
    end
    prev_x, prev_y_p = x, y
  end

  local arc_start, arc_end = ANGLE_MID, angle
  if arc_start > arc_end then arc_start, arc_end = arc_end, arc_start end

  prev_x, prev_y_p = nil, nil
  for i = 0, segments do
    local t = i / segments
    local a = ANGLE_MIN + t * (ANGLE_MAX - ANGLE_MIN)
    if a >= arc_start and a <= arc_end then
      local x = cx + math.cos(a) * (radius - track_w * 0.5)
      local y = cy + math.sin(a) * (radius - track_w * 0.5)
      if prev_x then
        reaper.ImGui_DrawList_AddLine(draw_list, prev_x, prev_y_p, x, y, col_arc, track_w)
      end
      prev_x, prev_y_p = x, y
    else
      prev_x, prev_y_p = nil, nil
    end
  end

  local px0 = cx + math.cos(angle) * (radius * 0.35)
  local py0 = cy + math.sin(angle) * (radius * 0.35)
  local px1 = cx + math.cos(angle) * (radius * 0.75)
  local py1 = cy + math.sin(angle) * (radius * 0.75)
  reaper.ImGui_DrawList_AddLine(draw_list, px0, py0, px1, py1, col_ptr, pointer_w)
  reaper.ImGui_DrawList_AddCircleFilled(draw_list, cx, cy, 4, 0xAAAAAAFF)
end

local function close(cancel)
  if cancel then
    reaper.SetMediaTrackInfo_Value(track, "D_VOL", init_vol)
    reaper.Undo_EndBlock("Track volume (cancelled)", -1)
  else
    reaper.Undo_EndBlock("Track volume: " .. track_name, -1)
  end
end

local function loop()
  local cur_btn = reaper.JS_Mouse_GetState(0x07)
  local clicked = (cur_btn ~= 0) and (prev_btn == 0)
  prev_btn = cur_btn

  reaper.ImGui_PushFont(ctx, font, 14)
  reaper.ImGui_PushStyleVar(ctx,   reaper.ImGui_StyleVar_WindowRounding(), 12)
  reaper.ImGui_PushStyleVar(ctx,   reaper.ImGui_StyleVar_WindowPadding(),  16, 12)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), 0x1E1E1EEE)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),     0xEEEEEEFF)

  reaper.ImGui_SetNextWindowSize(ctx, WIN_W, WIN_H, reaper.ImGui_Cond_Always())
  reaper.ImGui_SetNextWindowPos(ctx, mx0 - WIN_W * 0.5, my0 - WIN_H * 0.5, reaper.ImGui_Cond_Once())

  local visible, open = reaper.ImGui_Begin(ctx, "##trackvol",
    true,
    reaper.ImGui_WindowFlags_NoCollapse() |
    reaper.ImGui_WindowFlags_NoTitleBar() |
    reaper.ImGui_WindowFlags_NoResize()   |
    reaper.ImGui_WindowFlags_NoNav()      |
    reaper.ImGui_WindowFlags_NoMove()
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
      local vol = reaper.GetMediaTrackInfo_Value(track, "D_VOL")
      vol = math.max(0, vol + dy * SENSITIVITY)
      reaper.SetMediaTrackInfo_Value(track, "D_VOL", vol)
    end

    local vol      = reaper.GetMediaTrackInfo_Value(track, "D_VOL")
    local vol_db   = to_db(vol)
    local init_db  = to_db(init_vol)
    local delta    = (vol_db and init_db) and (vol_db - init_db) or nil
    local delta_str
    if not delta then
      delta_str = "-inf"
    elseif delta >= 0 then
      delta_str = string.format("+%.1f", delta)
    else
      delta_str = string.format("%.1f", delta)
    end

    local avail_w = reaper.ImGui_GetContentRegionAvail(ctx)
    local knob_r  = 55
    local knob_cx = avail_w * 0.5
    local angle   = delta_to_angle(delta)
    local dl      = reaper.ImGui_GetWindowDrawList(ctx)
    local wx, wy  = reaper.ImGui_GetCursorScreenPos(ctx)

    local delta_label = delta_str .. " dB"
    local dtw = reaper.ImGui_CalcTextSize(ctx, delta_label)
    reaper.ImGui_DrawList_AddText(dl, wx + knob_cx - dtw * 0.5, wy, 0xEEEEEEFF, delta_label)

    local text_h = reaper.ImGui_GetTextLineHeight(ctx)
    draw_knob(dl, wx + knob_cx, wy + text_h + 6 + knob_r, knob_r, angle, delta)

    reaper.ImGui_Dummy(ctx, avail_w, text_h + 6 + knob_r * 2 + 10)

    local db_str = fmt_db(vol_db) .. " dB"
    local tw1    = reaper.ImGui_CalcTextSize(ctx, db_str)
    reaper.ImGui_SetCursorPosX(ctx, (WIN_W - tw1) * 0.5)
    reaper.ImGui_TextDisabled(ctx, db_str)

    reaper.ImGui_Spacing(ctx)
    local tw2 = reaper.ImGui_CalcTextSize(ctx, track_name)
    reaper.ImGui_SetCursorPosX(ctx, (WIN_W - tw2) * 0.5)
    reaper.ImGui_TextDisabled(ctx, track_name)

    reaper.ImGui_End(ctx)
  end

  reaper.ImGui_PopStyleColor(ctx, 2)
  reaper.ImGui_PopStyleVar(ctx, 2)
  reaper.ImGui_PopFont(ctx)

  if open then reaper.defer(loop) end
end

reaper.defer(loop)
