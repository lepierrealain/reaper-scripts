-- @description Show first active instrument on track under mouse (picker if multiple, add from favs if none)
-- @author lepierrealain
-- @version 1.4
-- @requires js_ReaScriptAPI, ReaImGui

local lib_path = ({ reaper.get_action_context() })[2]:match("^(.+[\\/])")
local lib_root = lib_path .. ".." .. package.config:sub(1,1) .. "Libraries" .. package.config:sub(1,1)
dofile(lib_root .. "PA_lib_track.lua")

local mouse_x, mouse_y = reaper.GetMousePosition()
local track = reaper.GetSelectedTrack(0, 0)
if not track then return end

local instruments = {}
local fx_count = reaper.TrackFX_GetCount(track)
for i = 0, fx_count - 1 do
  local _, name = reaper.TrackFX_GetFXName(track, i)
  local p = name:lower()
  if (p:find("^vsti:") or p:find("^vst3i:") or p:find("^clapi:")) and reaper.TrackFX_GetEnabled(track, i) then
    local display = (name:match("^[^:]+:%s*(.+)$") or name):gsub("%s*%b()%s*", " "):match("^%s*(.-)%s*$")
    instruments[#instruments + 1] = { idx = i, name = display }
  end
end

if #instruments == 1 then
  reaper.TrackFX_Show(track, instruments[1].idx, 3)
  return
end

if #instruments == 0 then
  -- Open Add Plugin with /i pre-filled, centred on mouse
  local EXT = "PA_AddPlugin"
  reaper.SetExtState(EXT, "init_filter", "/i", false)
  reaper.SetExtState(EXT, "init_mini",   "1",  false)
  local script_path = ({ reaper.get_action_context() })[2]
  local dir = script_path:match("^(.+[\\/])")
  dofile(dir .. "PA_Add plugin.lua")
  return
end

-- Multiple instruments: show picker
local ctx  = reaper.ImGui_CreateContext("PA_ShowInstrument")
local font = reaper.ImGui_CreateFont("sans-serif", 18)
reaper.ImGui_Attach(ctx, font)

local win_init = true

local function loop()
  reaper.ImGui_PushFont(ctx, font, 18)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowRounding(),  10)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(),   14, 14)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(),   8)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(),    10, 7)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(),     8, 8)

  if win_init then
    local w, h = 300, #instruments * 46 + 28
    reaper.ImGui_SetNextWindowPos(ctx, mouse_x - w * 0.5, mouse_y - h * 0.5, reaper.ImGui_Cond_Always())
    reaper.ImGui_SetNextWindowSize(ctx, w, h)
    win_init = false
  end

  local visible = reaper.ImGui_Begin(ctx, "Show Instrument", nil,
    reaper.ImGui_WindowFlags_NoCollapse() | reaper.ImGui_WindowFlags_NoNav() |
    reaper.ImGui_WindowFlags_NoTitleBar() | reaper.ImGui_WindowFlags_NoResize())
  local open = true

  if visible then
    if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) or
       not reaper.ImGui_IsWindowFocused(ctx, reaper.ImGui_FocusedFlags_AnyWindow()) then
      open = false
    end
    for _, instr in ipairs(instruments) do
      if reaper.ImGui_Button(ctx, instr.name, -1, 0) then
        reaper.TrackFX_Show(track, instr.idx, 3)
        open = false
      end
    end
  end

  reaper.ImGui_End(ctx)
  reaper.ImGui_PopStyleVar(ctx, 5)
  reaper.ImGui_PopFont(ctx)

  if open then reaper.defer(loop) end
end

reaper.defer(loop)
