-- @description Show FX by tag category (used by PA_Show *.lua scripts)
-- @author lepierrealain
-- @version 1.0

function PA_AddFX(tag_key, tag_prefix, ctx_name, caller_path)
  local track = reaper.GetSelectedTrack(0, 0)
  if not track then return end

  local EXT = "PA_AddPlugin"
  reaper.SetExtState(EXT, "init_filter", tag_prefix, false)
  reaper.SetExtState(EXT, "init_mini",   "1",        false)
  local sep = package.config:sub(1,1)
  local dir = caller_path:match("^(.+[\\/])")
  dofile(dir .. ".." .. sep .. "Custom" .. sep .. "PA_Add plugin.lua")
end

function PA_ShowFX(tag_key, tag_prefix, ctx_name, caller_path)
  local mouse_x, mouse_y = reaper.GetMousePosition()
  local track = reaper.GetSelectedTrack(0, 0)
  if not track then return end

  local tagged = {}
  local raw = reaper.GetExtState("PA_AddPlugin", tag_key)
  for name in raw:gmatch("([^|]+)") do
    tagged[name:lower()] = name
  end

  local matches = {}
  for i = 0, reaper.TrackFX_GetCount(track) - 1 do
    if reaper.TrackFX_GetEnabled(track, i) then
      local _, fx_name = reaper.TrackFX_GetFXName(track, i)
      if tagged[fx_name:lower()] then
        local display = (fx_name:match("^[^:]+:%s*(.+)$") or fx_name):gsub("%s*%b()%s*", " "):match("^%s*(.-)%s*$")
        matches[#matches + 1] = { idx = i, name = display }
      end
    end
  end

  if #matches == 1 then
    reaper.TrackFX_Show(track, matches[1].idx, 3)
    return
  end

  if #matches == 0 then
    local EXT = "PA_AddPlugin"
    reaper.SetExtState(EXT, "init_filter", tag_prefix, false)
    reaper.SetExtState(EXT, "init_mini",   "1",        false)
    local sep = package.config:sub(1,1)
    local dir = caller_path:match("^(.+[\\/])")
    dofile(dir .. ".." .. sep .. "Custom" .. sep .. "PA_Add plugin.lua")
    return
  end

  -- Multiple matches: show picker
  local ctx  = reaper.ImGui_CreateContext(ctx_name)
  local font = reaper.ImGui_CreateFont("sans-serif", 18)
  reaper.ImGui_Attach(ctx, font)

  local win_init = true

  local function loop()
    reaper.ImGui_PushFont(ctx, font, 18)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowRounding(), 10)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(),  14, 14)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(),  8)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(),   10, 7)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(),    8, 8)

    if win_init then
      local w = 300
      local h = #matches * 46 + 28
      reaper.ImGui_SetNextWindowPos(ctx, mouse_x - w * 0.5, mouse_y - h * 0.5, reaper.ImGui_Cond_Always())
      reaper.ImGui_SetNextWindowSize(ctx, w, h)
      win_init = false
    end

    local visible = reaper.ImGui_Begin(ctx, ctx_name, nil,
      reaper.ImGui_WindowFlags_NoCollapse() | reaper.ImGui_WindowFlags_NoNav() |
      reaper.ImGui_WindowFlags_NoTitleBar() | reaper.ImGui_WindowFlags_NoResize())
    local open = true

    if visible then
      if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) or
         not reaper.ImGui_IsWindowFocused(ctx, reaper.ImGui_FocusedFlags_AnyWindow()) then
        open = false
      end
      for _, m in ipairs(matches) do
        if reaper.ImGui_Button(ctx, m.name, -1, 0) then
          reaper.TrackFX_Show(track, m.idx, 3)
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
end
