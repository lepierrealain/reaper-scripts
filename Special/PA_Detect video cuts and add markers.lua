-- @description Detect cuts in selected video items and add project markers
-- @author lepierrealain
-- @version 1.2
-- @about
--   Requires the ffmpeg command-line program in PATH (or set FFMPEG below).
--   Detects scene changes in the active take of each selected item, then maps
--   source timestamps to the project, including trims, play rate, source
--   sections/reverse and item loops. Sensitivity is set with a 0-100% slider.

local FFMPEG = "ffmpeg" -- Full path to ffmpeg.exe can be used if needed.
local MARKER_NAME = "Cut"
local EPSILON = 0.000001
local MAX_THRESHOLD = 0.5
local MIN_THRESHOLD = 0.05
local function message(text)
  reaper.ShowMessageBox(text, "Détection des cuts vidéo", 0)
end

local selected_count = reaper.CountSelectedMediaItems(0)
if selected_count == 0 then
  message("Sélectionnez au moins un item vidéo.")
  return
end

local function quote(arg)
  return '"' .. arg:gsub('"', '\\"') .. '"'
end

local function run(command)
  local result = reaper.ExecProcess(command, 0)
  if not result then return nil, "Impossible de lancer FFmpeg." end
  local status, output = result:match("^(-?%d+)\r?\n(.*)$")
  if not status then return nil, "Réponse inattendue de FFmpeg." end
  if tonumber(status) ~= 0 then
    return nil, (output or ""):match("([^\r\n]+)%s*$") or "FFmpeg a échoué."
  end
  return output
end

local function process(threshold)
local selected_count = reaper.CountSelectedMediaItems(0)
if selected_count == 0 then
  message("Sélectionnez au moins un item vidéo.")
  return
end

local version, version_error = run(quote(FFMPEG) .. " -version")
if not version then
  message("FFmpeg est introuvable ou inutilisable. Installez-le dans le PATH ou indiquez son chemin dans FFMPEG en haut du script.\n\n" .. version_error)
  return
end

-- Framehash writes selected frame timestamps to stdout, avoiding FFmpeg's
-- stderr log (which ExecProcess is not guaranteed to capture).
local function detect_cuts(path)
  local ffmpeg_threshold = string.format("%.3f", threshold):gsub(",", ".")
  local filter = "select=gt(scene\\," .. ffmpeg_threshold .. ")"
  local command = quote(FFMPEG) .. " -hide_banner -loglevel error -nostdin -i "
    .. quote(path) .. " -map 0:v:0 -an -sn -dn -vf " .. quote(filter)
    .. " -fps_mode passthrough -enc_time_base:v 1:1000000 -f framehash -"
  local output, err = run(command)
  if not output then return nil, err end

  local num, den = output:match("#tb%s+0:%s*(%d+)%s*/%s*(%d+)")
  if not num or tonumber(den) == 0 then
    return nil, "Aucune piste vidéo lisible ou horodatages FFmpeg absents."
  end

  local seconds_per_tick = tonumber(num) / tonumber(den)
  local cuts = {}
  for line in output:gmatch("[^\r\n]+") do
    local stream, _, pts = line:match("^%s*(%d+)%s*,%s*(-?%d+)%s*,%s*(-?%d+)%s*,")
    if stream == "0" then
      cuts[#cuts + 1] = tonumber(pts) * seconds_per_tick
    end
  end
  return cuts
end

-- Convert a take source's time to the underlying file's time. A section or
-- reverse source wraps its parent; each wrapper is an affine transformation.
local function source_mapping(source)
  local scale, offset = 1, 0
  local current = source
  while reaper.GetMediaSourceParent(current) do
    local has_section, section_offset, section_length, reverse =
      reaper.PCM_Source_GetSectionInfo(current)
    if not has_section then return nil end
    local sign = reverse and -1 or 1
    local origin = section_offset + (reverse and section_length or 0)
    scale, offset = sign * scale, sign * offset + origin
    current = reaper.GetMediaSourceParent(current)
  end
  return current, scale, offset
end

local items = {}
local skipped = 0
for i = 0, selected_count - 1 do
  local item = reaper.GetSelectedMediaItem(0, i)
  local take = reaper.GetActiveTake(item)
  if take and not reaper.TakeIsMIDI(take)
    and reaper.GetTakeNumStretchMarkers(take) == 0 then
    local source = reaper.GetMediaItemTake_Source(take)
    if source then
      local root, scale, offset = source_mapping(source)
      if root then
        local path = reaper.GetMediaSourceFileName(root)
        local source_length, is_qn = reaper.GetMediaSourceLength(source)
        local rate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
        if path ~= "" and reaper.file_exists(path) and rate > 0
          and not is_qn and source_length > 0 then
          items[#items + 1] = {
            path = path,
            scale = scale,
            offset = offset,
            source_length = source_length,
            position = reaper.GetMediaItemInfo_Value(item, "D_POSITION"),
            length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH"),
            start_offset = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS"),
            rate = rate,
            loop = reaper.GetMediaItemInfo_Value(item, "B_LOOPSRC") ~= 0,
          }
        else
          skipped = skipped + 1
        end
      else
        skipped = skipped + 1
      end
    else
      skipped = skipped + 1
    end
  else
    skipped = skipped + 1
  end
end

if #items == 0 then
  message("Aucun item vidéo exploitable. Les prises avec marqueurs d'étirement ne sont pas prises en charge.")
  return
end

local cache = {}
local positions = {}
local failed = 0
for _, item in ipairs(items) do
  local result = cache[item.path]
  if result == nil then
    local cuts, err = detect_cuts(item.path)
    result = cuts or false
    cache[item.path] = result
    if not cuts then
      reaper.ShowConsoleMsg("FFmpeg : " .. item.path .. " : " .. err .. "\n")
    end
  end
  if result == false then
    failed = failed + 1
  else
    for _, file_time in ipairs(result) do
      local source_time = (file_time - item.offset) / item.scale
      if source_time >= -EPSILON and source_time < item.source_length - EPSILON then
        local first = (source_time - item.start_offset) / item.rate
        if item.loop then
          local period = item.source_length / item.rate
          local k = math.max(0, math.ceil((EPSILON - first) / period))
          while first + k * period < item.length - EPSILON do
            positions[#positions + 1] = item.position + first + k * period
            k = k + 1
          end
        elseif first > EPSILON and first < item.length - EPSILON then
          positions[#positions + 1] = item.position + first
        end
      end
    end
  end
end

-- Deduplicate overlapping selected items and markers from earlier runs.
local existing = {}
local _, marker_count, region_count = reaper.CountProjectMarkers(0)
for i = 0, marker_count + region_count - 1 do
  local valid, is_region, position, _, name = reaper.EnumProjectMarkers(i)
  if valid > 0 and not is_region and name == MARKER_NAME then
    existing[#existing + 1] = position
  end
end
table.sort(existing)
table.sort(positions)

local created = 0
local previous
local existing_index = 1
reaper.Undo_BeginBlock()
for _, position in ipairs(positions) do
  while existing_index <= #existing and existing[existing_index] < position - EPSILON do
    existing_index = existing_index + 1
  end
  local already_exists = existing_index <= #existing
    and math.abs(existing[existing_index] - position) <= EPSILON
  if (not previous or math.abs(position - previous) > EPSILON) and not already_exists then
    reaper.AddProjectMarker2(0, false, position, 0, MARKER_NAME, -1, 0)
    created = created + 1
  end
  previous = position
end
reaper.Undo_EndBlock("Détecter les cuts vidéo et placer des marqueurs", -1)
if created > 0 then reaper.UpdateArrange() end

local summary = created .. " marqueur(s) ajouté(s)."
if skipped > 0 then summary = summary .. "\n" .. skipped .. " item(s) ignoré(s)." end
if failed > 0 then summary = summary .. "\n" .. failed .. " item(s) en échec FFmpeg (détails dans la console)." end
message(summary)
end

-- gfx provides a native ReaScript window without an extension dependency.
-- 0% = 0.5 (fewer detections); 100% = 0.05 (more detections).
local sensitivity = (MAX_THRESHOLD - 0.3) / (MAX_THRESHOLD - MIN_THRESHOLD)
local dragging = false
local previous_mouse_down = false

local function threshold_from_sensitivity(value)
  return MAX_THRESHOLD - (MAX_THRESHOLD - MIN_THRESHOLD) * value
end

local function clamp(value)
  return math.max(0, math.min(1, value))
end

local function draw_text(x, y, value, r, g, b)
  gfx.set(r or 0.9, g or 0.9, b or 0.9)
  gfx.x, gfx.y = x, y
  gfx.drawstr(value)
end

local function draw_button(x, y, width, label, active)
  if active then gfx.set(0.20, 0.52, 0.78) else gfx.set(0.25, 0.27, 0.30) end
  gfx.rect(x, y, width, 32)
  gfx.set(1, 1, 1)
  local text_width = gfx.measurestr(label)
  gfx.x, gfx.y = x + (width - text_width) / 2, y + 7
  gfx.drawstr(label)
end

local function draw_ui()
  local key = gfx.getchar()
  if key == -1 or key == 27 then
    gfx.quit()
    return
  end

  local left, right = 32, math.max(33, gfx.w - 32)
  local slider_y = 80
  local button_y = 145
  local button_width = 100
  local ok_x = math.max(12, gfx.w - button_width - 28)
  local cancel_x = ok_x - button_width - 12
  local mouse_down = gfx.mouse_cap % 2 == 1
  local pressed = mouse_down and not previous_mouse_down

  if pressed and gfx.mouse_x >= left - 12 and gfx.mouse_x <= right + 12
    and math.abs(gfx.mouse_y - slider_y) <= 18 then
    dragging = true
  end
  if not mouse_down then dragging = false end
  if dragging then sensitivity = clamp((gfx.mouse_x - left) / (right - left)) end
  previous_mouse_down = mouse_down

  local confirm = key == 13 or (pressed and gfx.mouse_x >= ok_x
    and gfx.mouse_x <= ok_x + button_width
    and gfx.mouse_y >= button_y and gfx.mouse_y <= button_y + 32)
  local cancel = pressed and gfx.mouse_x >= cancel_x
    and gfx.mouse_x <= cancel_x + button_width
    and gfx.mouse_y >= button_y and gfx.mouse_y <= button_y + 32
  if confirm or cancel then
    gfx.quit()
    if confirm then process(threshold_from_sensitivity(sensitivity)) end
    return
  end

  gfx.set(0.12, 0.13, 0.15)
  gfx.rect(0, 0, gfx.w, gfx.h)
  gfx.setfont(1, "Arial", 16)
  local percent = math.floor(sensitivity * 100 + 0.5)
  local threshold = string.format("%.3f", threshold_from_sensitivity(sensitivity)):gsub(",", ".")
  draw_text(32, 20, "Sensibilité : " .. percent .. " %")
  draw_text(32, 43, "Seuil FFmpeg : " .. threshold, 0.72, 0.77, 0.82)

  gfx.set(0.34, 0.36, 0.39)
  gfx.rect(left, slider_y - 3, right - left, 6)
  gfx.set(0.20, 0.52, 0.78)
  gfx.rect(left, slider_y - 3, (right - left) * sensitivity, 6)
  gfx.circle(left + (right - left) * sensitivity, slider_y, 9, true)
  draw_text(left, 103, "0 %  (0.5)", 0.72, 0.77, 0.82)
  local right_label = "100 %  (0.05)"
  local label_width = gfx.measurestr(right_label)
  draw_text(right - label_width, 103, right_label, 0.72, 0.77, 0.82)
  draw_button(cancel_x, button_y, button_width, "Annuler", false)
  draw_button(ok_x, button_y, button_width, "Analyser", true)

  gfx.update()
  reaper.defer(draw_ui)
end

local window_width, window_height = 430, 195
local mouse_x, mouse_y = reaper.GetMousePosition()
local screen_left, screen_top, screen_right, screen_bottom =
  reaper.my_getViewport(0, 0, 0, 0, mouse_x, mouse_y, mouse_x + 1, mouse_y + 1, true)
local window_x = math.floor((screen_left + screen_right - window_width) / 2)
local window_y = math.floor((screen_top + screen_bottom - window_height) / 2)
gfx.init("Sensibilité de détection des cuts", window_width, window_height, 0, window_x, window_y)
draw_ui()
