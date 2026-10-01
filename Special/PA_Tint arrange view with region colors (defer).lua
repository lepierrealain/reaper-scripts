-- @description Tint arrange view with visible region colors (defer)
-- @author lepierrealain
-- @version 1.3
-- @requires js_ReaScriptAPI
-- @about
--   Toggle script. Adds a very subtle vertical tint across the arrange view
--   for each visible region, including colors inherited from ruler lanes.
--   Requires js_ReaScriptAPI.
--   Run again to remove the tint. Change OPACITY below to adjust its strength.

local r = reaper

local OPACITY = 0.10 -- 0.0 to 1.0
local REFRESH_INTERVAL = 0.02
local COMPOSITE_DELAY = 0.05
local SCROLL_SETTLE_DELAY = 0.08
local ARRANGE_WINDOW_ID = 1000
local IS_WINDOWS = r.GetOS():match("^Win") ~= nil

if not (r.JS_Window_FindChildByID and r.JS_Window_GetClientRect
    and r.JS_Window_IsWindow
    and r.JS_Window_InvalidateRect
    and r.JS_LICE_CreateBitmap and r.JS_LICE_DestroyBitmap
    and r.JS_LICE_Clear and r.JS_LICE_FillRect
    and r.JS_Composite and r.JS_Composite_Unlink) then
  r.MB("This script requires the js_ReaScriptAPI extension.",
    "Region color overlay", 0)
  return
end

local _, _, section_id, command_id = r.get_action_context()
if r.set_action_options then r.set_action_options(1) end

local arrange_window = nil
local bitmap = nil
local bitmap_width, bitmap_height = 0, 0
local current_project = nil
local project_change = nil
local regions = {}
local last_view_start, last_view_end = nil, nil
local last_refresh = 0
local previous_composite_delay = nil
local pending_repaint_at = nil

local function release_bitmap()
  if bitmap then
    if arrange_window and r.JS_Window_IsWindow(arrange_window) then
      r.JS_Composite_Unlink(arrange_window, bitmap, true)
    end
    r.JS_LICE_DestroyBitmap(bitmap)
    bitmap = nil
  end
  bitmap_width, bitmap_height = 0, 0
end

local function release_window()
  if previous_composite_delay and arrange_window
      and r.JS_Window_IsWindow(arrange_window) then
    r.JS_Composite_Delay(arrange_window,
      previous_composite_delay.min_time,
      previous_composite_delay.max_time,
      previous_composite_delay.max_bitmaps)
  end
  previous_composite_delay = nil
  release_bitmap()
end

local function configure_composite_delay()
  if not (IS_WINDOWS and r.JS_Composite_Delay and arrange_window) then return end
  local ok, min_time, max_time, max_bitmaps =
    r.JS_Composite_Delay(arrange_window, COMPOSITE_DELAY, COMPOSITE_DELAY, 2)
  if ok > 0 then
    previous_composite_delay = {
      min_time = min_time,
      max_time = max_time,
      max_bitmaps = max_bitmaps,
    }
  end
end

local function read_regions(project)
  local visible = {}

  local function add_region(start_pos, end_pos, native_color)
    if end_pos <= start_pos or native_color == 0 then return end
    local red, green, blue = r.ColorFromNative(native_color & 0xFFFFFF)
    visible[#visible + 1] = {
      start_pos = start_pos,
      end_pos = end_pos,
      red = red,
      green = green,
      blue = blue,
    }
  end

  -- REAPER 7.29+: the displayed color includes the ruler lane's color when a
  -- region has no custom color of its own. B_VISIBLE also excludes hidden lanes.
  if r.GetNumRegionsOrMarkers and r.GetRegionOrMarker
      and r.GetRegionOrMarkerInfo_Value then
    local count = r.GetNumRegionsOrMarkers(project)
    for i = 0, count - 1 do
      local marker = r.GetRegionOrMarker(project, i, "")
      if marker and r.GetRegionOrMarkerInfo_Value(project, marker, "B_ISREGION") ~= 0
          and r.GetRegionOrMarkerInfo_Value(project, marker, "B_VISIBLE") ~= 0 then
        add_region(
          r.GetRegionOrMarkerInfo_Value(project, marker, "D_STARTPOS"),
          r.GetRegionOrMarkerInfo_Value(project, marker, "D_ENDPOS"),
          math.floor(r.GetRegionOrMarkerInfo_Value(project, marker, "I_DISPLAYEDCOLOR"))
        )
      end
    end
  else
    -- Older REAPER versions have no ruler lanes or displayed-color API.
    local count = r.CountProjectMarkers(project)
    for i = 0, count - 1 do
      local ok, is_region, start_pos, end_pos, _, _, native_color =
        r.EnumProjectMarkers3(project, i)
      if ok ~= 0 and is_region and (native_color & 0x1000000) ~= 0 then
        add_region(start_pos, end_pos, native_color)
      end
    end
  end

  -- Draw outer regions first so a nested region keeps its own tint.
  table.sort(visible, function(a, b)
    if a.start_pos ~= b.start_pos then return a.start_pos < b.start_pos end
    return a.end_pos > b.end_pos
  end)

  return visible
end

local function overlay_color(region)
  local alpha = math.floor(255 * OPACITY + 0.5)
  local red, green, blue = region.red, region.green, region.blue

  -- Windows AlphaBlend expects premultiplied RGB in the LICE bitmap.
  if IS_WINDOWS then
    red = math.floor(red * alpha / 255 + 0.5)
    green = math.floor(green * alpha / 255 + 0.5)
    blue = math.floor(blue * alpha / 255 + 0.5)
  end

  return (alpha << 24) | (red << 16) | (green << 8) | blue
end

local function draw_regions(view_start, view_end, invalidate_now)
  r.JS_LICE_Clear(bitmap, 0x00000000)
  local pixels_per_second = bitmap_width / (view_end - view_start)

  for _, region in ipairs(regions) do
    if region.end_pos > view_start and region.start_pos < view_end then
      local left = math.max(0, math.floor((region.start_pos - view_start) * pixels_per_second))
      local right = math.min(bitmap_width,
        math.ceil((region.end_pos - view_start) * pixels_per_second))
      if right > left then
        r.JS_LICE_FillRect(bitmap, left, 0, right - left, bitmap_height,
          overlay_color(region), 1, "COPY")
      end
    end
  end

  -- During scrolling REAPER already repaints the arrange view. An additional
  -- invalidate here would double the WM_PAINT traffic and increase flicker.
  return r.JS_Composite(arrange_window, 0, 0, bitmap_width, bitmap_height,
    bitmap, 0, 0, bitmap_width, bitmap_height, invalidate_now) > 0
end

local function loop()
  local now = r.time_precise()
  if now - last_refresh < REFRESH_INTERVAL then
    r.defer(loop)
    return
  end
  last_refresh = now

  local window = r.JS_Window_FindChildByID(r.GetMainHwnd(), ARRANGE_WINDOW_ID)
  if window ~= arrange_window then
    release_window()
    arrange_window = window
    configure_composite_delay()
    last_view_start, last_view_end = nil, nil
    pending_repaint_at = nil
  end

  if arrange_window then
    local ok, screen_left, screen_top, screen_right, screen_bottom =
      r.JS_Window_GetClientRect(arrange_window)
    local width = ok and screen_right - screen_left or 0
    local height = ok and screen_bottom - screen_top or 0
    if ok and width > 0 and height > 0 then
      local project = r.EnumProjects(-1)
      local change = r.GetProjectStateChangeCount(project)
      local regions_changed = project ~= current_project or change ~= project_change
      if regions_changed then
        regions = read_regions(project)
        current_project, project_change = project, change
      end

      -- Ask REAPER for the times at the exact screen edges of this client area.
      -- The default full-view time span is not always the same width in pixels.
      local view_start, view_end = r.GetSet_ArrangeView2(project, false,
        screen_left, screen_right, 0, 0)
      if view_end > view_start then
        local size_changed = width ~= bitmap_width or height ~= bitmap_height
        if size_changed then
          release_bitmap()
          bitmap = r.JS_LICE_CreateBitmap(true, width, height)
          if not bitmap then
            r.MB("Could not create the region overlay bitmap.",
              "Region color overlay", 0)
            return
          end
          bitmap_width, bitmap_height = width, height
        end

        local view_changed = view_start ~= last_view_start
          or view_end ~= last_view_end
        if size_changed or regions_changed or view_changed then
          local invalidate_now = size_changed or regions_changed
          if not draw_regions(view_start, view_end, invalidate_now) then
            r.MB("Could not draw the region overlay.",
              "Region color overlay", 0)
            return
          end
          last_view_start, last_view_end = view_start, view_end
          pending_repaint_at = view_changed and not invalidate_now
            and (now + SCROLL_SETTLE_DELAY) or nil
        elseif pending_repaint_at and now >= pending_repaint_at then
          -- Make sure the final scroll position is repainted once scrolling
          -- stops, even if REAPER's last paint preceded our bitmap update.
          r.JS_Window_InvalidateRect(arrange_window, 0, 0, width, height, false)
          pending_repaint_at = nil
        end
      end
    end
  end

  r.defer(loop)
end

r.atexit(function()
  release_window()
  r.SetToggleCommandState(section_id, command_id, 0)
  r.RefreshToolbar2(section_id, command_id)
end)

r.SetToggleCommandState(section_id, command_id, 1)
r.RefreshToolbar2(section_id, command_id)
r.defer(loop)
