-- @description Set track record template (MIDI / Input 1 / Input 2)
-- @author lepierrealain
-- @version 1.1
-- @provides [main] .
-- @requires js_ReaScriptAPI, ReaImGui

local lib_path = ({ reaper.get_action_context() })[2]:match("^(.+[\\/])")
local lib_root = lib_path .. ".." .. package.config:sub(1,1) .. "Libraries" .. package.config:sub(1,1)
dofile(lib_root .. "PA_lib_track.lua")

local ctx = reaper.ImGui_CreateContext("Set Track Template")
local font = reaper.ImGui_CreateFont("sans-serif", 18)
reaper.ImGui_Attach(ctx, font)

local templates = {
  { label = "MIDI",    fn = PA_SetTrackTemplateToMidi },
  { label = "Input 1", fn = function() PA_SetTrackTemplateToInput(1) end },
  { label = "Input 2", fn = function() PA_SetTrackTemplateToInput(2) end },
}

local win_init = true

local function loop()
  reaper.ImGui_PushFont(ctx, font, 18)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowRounding(),  10)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(),   14, 14)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(),   8)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(),    10, 7)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(),     8, 8)

  if win_init then
    local w, h = 250, #templates * 44 + 35
    local mx, my = reaper.GetMousePosition()
    reaper.ImGui_SetNextWindowPos(ctx, mx - w * 0.5, my - h * 0.5, reaper.ImGui_Cond_Always())
    reaper.ImGui_SetNextWindowSize(ctx, w, h)
    win_init = false
  end

  local visible = reaper.ImGui_Begin(ctx, "Set Track Template", nil,
    reaper.ImGui_WindowFlags_NoCollapse() | reaper.ImGui_WindowFlags_NoNav() |
    reaper.ImGui_WindowFlags_NoTitleBar() | reaper.ImGui_WindowFlags_NoResize())
  local open = true

  if visible then
    if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) or
       not reaper.ImGui_IsWindowFocused(ctx, reaper.ImGui_FocusedFlags_AnyWindow()) then
      open = false
    end

    for _, t in ipairs(templates) do
      if reaper.ImGui_Button(ctx, t.label, -1, 0) then
        reaper.Undo_BeginBlock()
        t.fn()
        reaper.Undo_EndBlock("Set track template: " .. t.label, -1)
        reaper.UpdateArrange()
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
