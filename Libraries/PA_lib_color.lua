-- @description Auto colorize: réglages partagés + logique de colorisation des pistes
-- @author lepierrealain
-- @version 1.2

-- Librairie partagée entre "PA_Auto colorize tracks" (watcher) et sa fenêtre
-- de réglages. Les réglages vivent dans la section PA_AutoColorize de
-- reaper-extstate.ini ; chaque piste colorisée par le script est marquée
-- P_EXT:PA_autocolor avec la couleur posée, ce qui permet de distinguer
-- "couleur du script" et "couleur choisie par l'utilisateur".

local EXT = "PA_AutoColorize"

local CUSTOM_FLAG = 0x1000000              -- bit "couleur custom" de I_CUSTOMCOLOR
local OWN_KEY = "P_EXT:PA_autocolor"       -- couleur posée par le script (native int)

local DEFAULT_PALETTE = {
  0xE8554E,  -- rouge
  0xF19C4C,  -- orange
  0xE9C46A,  -- doré (cf. PA_GuiCol.GOLD)
  0x7CB56B,  -- vert
  0x4EA5A2,  -- sarcelle
  0x5B8CFF,  -- bleu (cf. PA_GuiCol.ACCENT)
  0x8A6FE8,  -- violet
  0xD470B8,  -- rose
}

function PA_ColorDefaultPalette()
  local t = {}
  for i, v in ipairs(DEFAULT_PALETTE) do t[i] = v end
  return t
end

-- ─── Réglages (ext state) ───────────────────────────────────────────────

function PA_ColorLoadSettings()
  local s = { palette = {} }
  for hex in reaper.GetExtState(EXT, "palette"):gmatch("[^,]+") do
    local v = tonumber(hex, 16)
    if v then s.palette[#s.palette + 1] = v & 0xFFFFFF end
  end
  if #s.palette == 0 then s.palette = PA_ColorDefaultPalette() end

  s.mode        = reaper.GetExtState(EXT, "mode") == "random" and "random" or "loop"
  s.preserve    = reaper.GetExtState(EXT, "preserve") ~= "0"
  s.child_depth = tonumber(reaper.GetExtState(EXT, "child_depth")) or 1
  s.child_sat   = tonumber(reaper.GetExtState(EXT, "child_sat")) or 0.70
  s.child_lum   = tonumber(reaper.GetExtState(EXT, "child_lum")) or 1.15
  s.cumulative  = reaper.GetExtState(EXT, "cumulative") == "1"
  s.childless_same = reaper.GetExtState(EXT, "childless_same") == "1"
  s.seed        = tonumber(reaper.GetExtState(EXT, "seed")) or 0
  s.live        = reaper.GetExtState(EXT, "live") ~= "0"
  return s
end

function PA_ColorSaveSettings(s)
  local parts = {}
  for _, c in ipairs(s.palette) do parts[#parts + 1] = string.format("%06X", c) end
  reaper.SetExtState(EXT, "palette", table.concat(parts, ","), true)
  reaper.SetExtState(EXT, "mode", s.mode, true)
  reaper.SetExtState(EXT, "preserve", s.preserve and "1" or "0", true)
  reaper.SetExtState(EXT, "child_depth", tostring(s.child_depth), true)
  reaper.SetExtState(EXT, "child_sat", tostring(s.child_sat), true)
  reaper.SetExtState(EXT, "child_lum", tostring(s.child_lum), true)
  reaper.SetExtState(EXT, "cumulative", s.cumulative and "1" or "0", true)
  reaper.SetExtState(EXT, "childless_same", s.childless_same and "1" or "0", true)
  reaper.SetExtState(EXT, "seed", tostring(s.seed), true)
  reaper.SetExtState(EXT, "live", s.live and "1" or "0", true)
  -- Horodatage non persisté : réveille le watcher pour qu'il recharge/réapplique
  reaper.SetExtState(EXT, "stamp", tostring(reaper.time_precise()), false)
end

function PA_ColorStamp()
  return reaper.GetExtState(EXT, "stamp")
end

-- ─── Couleurs : RGB ↔ HSL ───────────────────────────────────────────────

local function rgbToHsl(rgb)
  local r = ((rgb >> 16) & 0xFF) / 255
  local g = ((rgb >> 8) & 0xFF) / 255
  local b = (rgb & 0xFF) / 255
  local max, min = math.max(r, g, b), math.min(r, g, b)
  local l = (max + min) / 2
  if max == min then return 0, 0, l end
  local d = max - min
  local sat = l > 0.5 and d / (2 - max - min) or d / (max + min)
  local h
  if max == r then h = (g - b) / d + (g < b and 6 or 0)
  elseif max == g then h = (b - r) / d + 2
  else h = (r - g) / d + 4 end
  return h / 6, sat, l
end

local function hue2rgb(p, q, t)
  if t < 0 then t = t + 1 end
  if t > 1 then t = t - 1 end
  if t < 1 / 6 then return p + (q - p) * 6 * t end
  if t < 1 / 2 then return q end
  if t < 2 / 3 then return p + (q - p) * (2 / 3 - t) * 6 end
  return p
end

local function hslToRgb(h, sat, l)
  local r, g, b
  if sat == 0 then
    r, g, b = l, l, l
  else
    local q = l < 0.5 and l * (1 + sat) or l + sat - l * sat
    local p = 2 * l - q
    r = hue2rgb(p, q, h + 1 / 3)
    g = hue2rgb(p, q, h)
    b = hue2rgb(p, q, h - 1 / 3)
  end
  return (math.floor(r * 255 + 0.5) << 16)
       | (math.floor(g * 255 + 0.5) << 8)
       |  math.floor(b * 255 + 0.5)
end

-- Déclinaison enfant : saturation/luminosité multipliées `levels` fois
-- (levels > 1 en mode dégradé cumulatif). Bornes pour éviter noir/blanc purs.
function PA_ColorChildShade(rgb, levels, sat_mult, lum_mult)
  local h, sat, l = rgbToHsl(rgb)
  for _ = 1, levels do
    sat = sat * sat_mult
    l = l * lum_mult
  end
  sat = math.max(0, math.min(1, sat))
  l = math.max(0.05, math.min(0.95, l))
  return hslToRgb(h, sat, l)
end

-- ─── Colorisation ───────────────────────────────────────────────────────

-- Hash déterministe d'une chaîne (mode aléatoire stable : la couleur d'une
-- piste ne change pas d'une passe à l'autre, seul le seed la re-tire).
local function hashString(str)
  local h = 5381
  for i = 1, #str do
    h = (h * 33 + str:byte(i)) % 0x7FFFFFFF
  end
  return h
end

-- Couleur custom actuelle de la piste en 0xRRGGBB, ou nil si couleur par défaut.
local function currentColor(track)
  local c = math.floor(reaper.GetMediaTrackInfo_Value(track, "I_CUSTOMCOLOR"))
  if c & CUSTOM_FLAG == 0 then return nil end
  local r, g, b = reaper.ColorFromNative(c & 0xFFFFFF)
  return (r << 16) | (g << 8) | b
end

local function toNative(rgb)
  return reaper.ColorToNative((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF) | CUSTOM_FLAG
end

-- true si le script a le droit de recoloriser cette piste.
-- Avec "préserver" : seulement couleur par défaut, ou couleur posée par le
-- script et pas retouchée depuis (I_CUSTOMCOLOR == valeur mémorisée en P_EXT).
local function mayColor(track, s, force)
  if force or not s.preserve then return true end
  local c = math.floor(reaper.GetMediaTrackInfo_Value(track, "I_CUSTOMCOLOR"))
  if c & CUSTOM_FLAG == 0 then return true end
  local _, own = reaper.GetSetMediaTrackInfo_String(track, OWN_KEY, "", false)
  return tonumber(own) == c
end

-- Applique la palette à toutes les pistes du projet selon les réglages `s`.
-- force = true : ignore l'option "préserver" et recolorise tout.
-- force_guids : ensemble tguid → true de pistes à coloriser même si
-- "préserver" les bloquerait (pistes nouvellement créées : REAPER peut les
-- faire naître avec une couleur custom, qui passerait pour un choix de
-- l'utilisateur).
-- Retourne le nombre de pistes modifiées.
function PA_ColorizeApply(s, force, force_guids)
  if #s.palette == 0 then return 0 end
  local N = math.max(1, math.floor(s.child_depth))

  local assigned = {}  -- track → couleur effective après cette passe (0xRRGGBB)
  local plan = {}
  local counter, last_idx = 0, nil

  -- Dernière piste à couleur propre : couleur posée et absence d'enfants
  -- (option "même couleur entre pistes sans enfant").
  local prev_own_rgb, prev_own_childless = nil, false

  -- Choix d'une couleur "propre" (piste au-dessus du niveau d'héritage).
  -- Le compteur avance même pour les pistes préservées : l'attribution
  -- reste stable quand on active/désactive l'option.
  local function pickOwn(track, has_children)
    local rgb
    -- Deux pistes sans enfant qui se suivent : même couleur. Un dossier
    -- repart toujours sur une nouvelle couleur.
    if s.childless_same and prev_own_childless and not has_children then
      rgb = prev_own_rgb
    else
      local idx
      if s.mode == "random" then
        idx = hashString(reaper.GetTrackGUID(track) .. "#" .. s.seed) % #s.palette + 1
        if idx == last_idx and #s.palette > 1 then
          idx = idx % #s.palette + 1  -- évite deux pistes voisines identiques
        end
      else
        idx = counter % #s.palette + 1
      end
      counter, last_idx = counter + 1, idx
      rgb = s.palette[idx]
    end
    prev_own_rgb, prev_own_childless = rgb, not has_children
    return rgb
  end

  for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    local depth = reaper.GetTrackDepth(track)
    local is_folder = reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH") == 1
    local rgb

    -- Couleur propre : au-dessus du niveau d'héritage, mais seulement pour
    -- le niveau 0 et les dossiers. Une piste sans enfants sous un dossier
    -- hérite toujours de lui, même au-dessus du seuil : avec "héritage dès
    -- le niveau 2", un dossier de niveau 0 sans sous-dossiers garde ainsi
    -- toutes ses pistes déclinées sur sa couleur.
    if depth < N and (depth == 0 or is_folder) then
      rgb = pickOwn(track, is_folder)
    else
      -- Ancêtre le plus proche à un niveau "couleur propre" (≤ N-1)
      local anc = reaper.GetParentTrack(track)
      while anc and reaper.GetTrackDepth(anc) > N - 1 do
        anc = reaper.GetParentTrack(anc)
      end
      local base = anc and (assigned[anc] or currentColor(anc))
      if base then
        local levels = 1
        if s.cumulative then
          levels = math.max(1, depth - reaper.GetTrackDepth(anc))
        end
        rgb = PA_ColorChildShade(base, levels, s.child_sat, s.child_lum)
      else
        rgb = pickOwn(track, is_folder)  -- parent sans couleur : couleur propre
      end
    end

    local track_force = force
    if not track_force and force_guids then
      track_force = force_guids[reaper.GetTrackGUID(track)] or false
    end
    if mayColor(track, s, track_force) then
      assigned[track] = rgb
      local native = toNative(rgb)
      if math.floor(reaper.GetMediaTrackInfo_Value(track, "I_CUSTOMCOLOR")) ~= native then
        plan[#plan + 1] = { track = track, native = native }
      end
    else
      -- Couleur utilisateur préservée : les enfants se déclinent dessus
      assigned[track] = currentColor(track) or rgb
    end
  end

  if #plan > 0 then
    reaper.PreventUIRefresh(1)
    for _, p in ipairs(plan) do
      reaper.SetMediaTrackInfo_Value(p.track, "I_CUSTOMCOLOR", p.native)
      reaper.GetSetMediaTrackInfo_String(p.track, OWN_KEY, tostring(p.native), true)
    end
    reaper.PreventUIRefresh(-1)
    reaper.TrackList_AdjustWindows(false)
    reaper.UpdateArrange()
  end

  return #plan
end
