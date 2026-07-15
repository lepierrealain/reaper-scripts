-- @description Auto colorize tracks from palette (background watcher)
-- @author lepierrealain
-- @version 1.1
-- @about
--   Toggle script meant to run in the background (toolbar or __startup.lua).
--   Colors every track in the project from the palette defined in
--   "PA_Auto colorize tracks (settings)": looped or random colors (stable
--   per track), children shaded from their parent's color. A pass is
--   applied on launch, then whenever a track is added, removed or moved in
--   the tree, or the settings change. With the "preserve" option, colors
--   set manually by the user are never overwritten; newly created tracks
--   are always colored, even when REAPER creates them with a custom color.

local lib_path = ({ reaper.get_action_context() })[2]:match("^(.+[\\/])")
local lib_root = lib_path .. ".." .. package.config:sub(1, 1) .. "Libraries" .. package.config:sub(1, 1)
dofile(lib_root .. "PA_lib_color.lua")

local _, _, section_id, cmd_id = reaper.get_action_context()

-- Relancer l'action termine l'instance précédente au lieu d'afficher le dialogue REAPER
if reaper.set_action_options then reaper.set_action_options(1) end

reaper.SetToggleCommandState(section_id, cmd_id, 1)
reaper.RefreshToolbar2(section_id, cmd_id)

local CHECK_INTERVAL = 0.5  -- secondes entre deux scans

local last_check = 0
local last_sig = nil     -- nil au départ : première passe immédiate
local known_guids = nil  -- pistes vues au scan précédent (détection des nouvelles)

-- Signature légère : réglages (stamp) + structure des pistes (GUID + profondeur).
-- Les couleurs n'en font pas partie : une retouche manuelle de couleur ne
-- déclenche pas de repasse (c'est l'option "préserver" qui protège, à la passe suivante).
local function signature()
  local parts = { PA_ColorStamp() }
  local guids = {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    local guid = reaper.GetTrackGUID(track)
    guids[guid] = true
    parts[#parts + 1] = guid .. reaper.GetTrackDepth(track)
  end
  return table.concat(parts), guids
end

local function loop()
  local now = reaper.time_precise()
  if now - last_check >= CHECK_INTERVAL then
    last_check = now
    local sig, guids = signature()
    if sig ~= last_sig then
      last_sig = sig
      -- Les pistes apparues depuis le dernier scan sont colorisées même si
      -- "préserver" les bloquerait : REAPER peut créer une piste déjà munie
      -- d'une couleur custom (préférence de couleur des nouvelles pistes,
      -- duplication, template), qui passerait sinon pour un choix de
      -- l'utilisateur. Au premier scan (known_guids nil), rien n'est forcé.
      local new_guids
      if known_guids then
        for guid in pairs(guids) do
          if not known_guids[guid] then
            new_guids = new_guids or {}
            new_guids[guid] = true
          end
        end
      end
      known_guids = guids
      PA_ColorizeApply(PA_ColorLoadSettings(), false, new_guids)
    end
  end
  reaper.defer(loop)
end

reaper.atexit(function()
  reaper.SetToggleCommandState(section_id, cmd_id, 0)
  reaper.RefreshToolbar2(section_id, cmd_id)
end)

reaper.defer(loop)
