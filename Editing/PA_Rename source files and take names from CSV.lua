-- @description Rename source files and take names from CSV
-- @author lepierrealain
-- @version 1.0
-- @about
--   Reads old_name,new_name from a CSV (comma or semicolon, UTF-8).
--   Renames matching source files in their current folder and every matching
--   take in the current project. Preserves source sections and item settings.
--   Shows a preview, saves a project backup and a reverse CSV before applying.
--   Disk renames cannot be undone with REAPER's Undo. Use the reverse CSV.

local TITLE = "Renommer fichiers et prises depuis un CSV"
local WINDOWS = reaper.GetOS():match("Win") ~= nil
local function fail(message) error(message, 0) end
local function key(path)
  path = path:gsub("\\", "/")
  return WINDOWS and path:lower() or path
end
local function basename(path) return path:match("[^/\\]+$") or path end
local function dirname(path) return path:match("^(.*[/\\])") or "" end
local function exists(path)
  local f = io.open(path, "rb")
  if f then f:close(); return true end
  return reaper.file_exists(path)
end
local function read(path)
  local f, err = io.open(path, "rb")
  if not f then fail("Lecture impossible : " .. path .. "\n" .. tostring(err)) end
  local data = f:read("*a"); f:close(); return data
end
local function write(path, data)
  if exists(path) then fail("Le fichier existe déjà : " .. path) end
  local f, err = io.open(path, "wb")
  if not f then fail("Écriture impossible : " .. path .. "\n" .. tostring(err)) end
  local ok, why = f:write(data)
  local closed, close_error = f:close()
  if not ok or not closed then fail("Écriture incomplète : " .. path .. "\n" .. tostring(why or close_error)) end
end

-- CSV state machine: escaped quotes, embedded newlines, CRLF and UTF-8 BOM.
local function parseCSV(data)
  data = data:gsub("^\239\187\191", "")
  local first = data:match("[^\r\n]*") or ""
  local delimiter = first:find(";", 1, true) and ";" or ","
  local rows, row, field, quoted, after_quote = {}, {}, {}, false, false
  local function cell()
    row[#row + 1] = table.concat(field); field = {}; after_quote = false
  end
  local function line()
    cell()
    if #row > 1 or row[1] ~= "" then rows[#rows + 1] = row end
    row = {}
  end
  local i = 1
  while i <= #data do
    local c = data:sub(i, i)
    if quoted then
      if c == '"' then
        if data:sub(i + 1, i + 1) == '"' then field[#field + 1] = '"'; i = i + 1
        else quoted = false; after_quote = true end
      else field[#field + 1] = c end
    elseif c == delimiter then cell()
    elseif c == "\r" or c == "\n" then
      line()
      if c == "\r" and data:sub(i + 1, i + 1) == "\n" then i = i + 1 end
    elseif c == '"' and #field == 0 and not after_quote then quoted = true
    elseif after_quote then
      if not c:match("%s") then fail("CSV mal formé après un guillemet.") end
    elseif c == '"' then fail("CSV mal formé : guillemet inattendu.")
    else field[#field + 1] = c end
    i = i + 1
  end
  if quoted then fail("CSV mal formé : guillemet non fermé.") end
  if #field > 0 or #row > 0 or after_quote then line() end
  return rows
end
local function validName(name)
  if name == "" or name == "." or name == ".." or name:find('[/\\%c"]') then return false end
  if WINDOWS then
    if name:find('[<>:|?*]') or name:match("[ .]$") then return false end
    local stem = name:match("^[^.]+"):upper()
    if stem == "CON" or stem == "PRN" or stem == "AUX" or stem == "NUL"
        or stem:match("^COM[1-9]$") or stem:match("^LPT[1-9]$") then return false end
  end
  return true
end
local function loadMap(path)
  local rows = parseCSV(read(path))
  local columns = {}
  for i, name in ipairs(rows[1] or {}) do columns[name:match("^%s*(.-)%s*$"):lower()] = i end
  if not columns.old_name or not columns.new_name then fail("Colonnes requises : old_name et new_name.") end
  local map, count = {}, 0
  for i = 2, #rows do
    local old, new = rows[i][columns.old_name], rows[i][columns.new_name]
    if not old or not new or not validName(old) or not validName(new) then fail("Nom invalide à la ligne " .. i) end
    if key(old:match("%.[^.]+$") or "") ~= key(new:match("%.[^.]+$") or "") then
      fail("L'extension doit rester identique (ligne " .. i .. ").")
    end
    if map[key(old)] then fail("Ancien nom en double : " .. old) end
    map[key(old)] = {old = old, new = new}; count = count + 1
  end
  if count == 0 then fail("Le CSV ne contient aucune correspondance.") end
  return map, count
end
local function absolute(path, project_dir)
  if path:match("^%a:[/\\]") or path:match("^[/\\]") then return path end
  return project_dir .. path
end
local function csvCell(value) return '"' .. value:gsub('"', '""') .. '"' end

local function main()
  if reaper.GetPlayState() ~= 0 then fail("Arrête la lecture et l'enregistrement avant de lancer le script.") end
  local project, project_file = reaper.EnumProjects(-1, "")
  if project_file == "" then fail("Enregistre d'abord le projet REAPER.") end
  local chosen, csv = reaper.GetUserFileNameForRead("K:\\Foley_renamed\\rename_map_updated.csv", TITLE, "csv")
  if not chosen then return end
  local map, total = loadMap(csv)
  local project_dir = dirname(project_file)
  local files, by_path, by_old, items, take_count, used = {}, {}, {}, {}, 0, {}
  for i = 0, reaper.CountMediaItems(project) - 1 do
    local item = reaper.GetMediaItem(project, i)
    local takes = {}
    for t = 0, reaper.CountTakes(item) - 1 do
      local take = reaper.GetTake(item, t)
      local source = reaper.GetMediaItemTake_Source(take)
      if source and not reaper.TakeIsMIDI(take) then
        while reaper.GetMediaSourceParent(source) do source = reaper.GetMediaSourceParent(source) end
        local path = reaper.GetMediaSourceFileName(source)
        local entry = map[key(basename(path))]
        if entry then
          path = absolute(path, project_dir)
          local path_key = key(path)
          if by_old[key(entry.old)] and by_old[key(entry.old)] ~= path_key then
            fail("Nom ambigu, utilisé dans plusieurs dossiers : " .. entry.old)
          end
          by_old[key(entry.old)] = path_key; used[key(entry.old)] = true
          if not by_path[path_key] then
            local file = {old = path, new = dirname(path) .. entry.new}
            if key(file.old) == key(file.new) and file.old ~= file.new then
              fail("Renommage de casse seule non pris en charge : " .. entry.old)
            end
            if not exists(file.old) then fail("Source introuvable : " .. file.old) end
            if file.old ~= file.new and exists(file.new) then fail("La destination existe déjà : " .. file.new) end
            by_path[path_key] = file; files[#files + 1] = file
          end
          takes[#takes + 1] = {index = t, name = entry.new}
          take_count = take_count + 1
        end
      end
    end
    if #takes > 0 then
      local ok, chunk = reaper.GetItemStateChunk(item, "", false)
      if not ok then fail("Impossible de lire les données d'un item.") end
      items[#items + 1] = {item = item, original = chunk, takes = takes}
    end
  end
  if #files == 0 then fail("Aucun fichier du projet ne correspond aux anciens noms du CSV.") end
  local destinations, destination_names = {}, {}
  for _, file in ipairs(files) do
    if destinations[key(file.new)] then fail("Plusieurs fichiers ont la même destination : " .. file.new) end
    if destination_names[key(basename(file.new))] then
      fail("Nouveau nom en double, incompatible avec le CSV inverse : " .. basename(file.new))
    end
    destinations[key(file.new)] = true
    destination_names[key(basename(file.new))] = true
  end
  -- Only rewrite FILE lines inside SOURCE blocks, leaving take FX data intact.
  for _, item in ipairs(items) do
    local stack, replacements = {}, 0
    item.updated = item.original:gsub("([^\n]*)(\n?)", function(line, newline)
      local block = line:match("^%s*<(%S+)")
      if block then stack[#stack + 1] = block end
      if stack[#stack] == "SOURCE" then
        local prefix, value, ending = line:match('^(%s*FILE%s+)"(.-)"(%s*)$')
        if not prefix then prefix, value, ending = line:match("^(%s*FILE%s+)(%S+)(%s*)$") end
        local file = value and by_path[key(absolute(value, project_dir))]
        if file then
          replacements = replacements + 1
          line = prefix .. '"' .. file.new .. '"' .. ending
        end
      end
      if line:match("^%s*>%s*$") then stack[#stack] = nil end
      return line .. newline
    end)
    if replacements < #item.takes then fail("Format de source non pris en charge ; aucune modification effectuée.") end
  end
  local stamp = os.date("%Y%m%d-%H%M%S")
  local backup = project_file .. ".before-csv-rename-" .. stamp .. ".rpp"
  local reverse = project_file .. ".reverse-rename-" .. stamp .. ".csv"
  if exists(backup) or exists(reverse) then fail("Une sauvegarde de cette opération existe déjà. Relance dans quelques secondes.") end
  local preview = {TITLE, "", string.format("%d fichiers, %d prises, %d items.", #files, take_count, #items)}
  local matched = 0
  for _ in pairs(used) do matched = matched + 1 end
  preview[#preview + 1] = (total - matched) .. " lignes du CSV absentes de ce projet."
  preview[#preview + 1] = ""
  for _, file in ipairs(files) do preview[#preview + 1] = file.old .. "\n  -> " .. file.new end
  reaper.ShowConsoleMsg(table.concat(preview, "\n") .. "\n")
  local answer = reaper.ShowMessageBox(string.format(
    "Renommer %d fichiers sur disque et %d prises dans tout le projet ?\n\nL'aperçu complet est dans la console. Les fichiers restent dans leur dossier actuel. Les noms de prises incluent l'extension.\n\nLe projet sera enregistré avant et après l'opération, avec une sauvegarde et un CSV inverse. Le renommage sur disque n'est pas annulable par Ctrl+Z et affecte les autres projets utilisant ces fichiers.", #files, take_count), TITLE, 1)
  if answer ~= 1 then return end
  reaper.Main_SaveProject(project, false)
  if reaper.IsProjectDirty(project) ~= 0 then fail("Le projet n'a pas pu être enregistré.") end
  write(backup, read(project_file))
  local lines = {"old_name,new_name"}
  for _, file in ipairs(files) do lines[#lines + 1] = csvCell(basename(file.new)) .. "," .. csvCell(basename(file.old)) end
  write(reverse, table.concat(lines, "\r\n") .. "\r\n")
  local renamed = {}
  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock2(project)
  local ok, err = xpcall(function()
    -- REAPER releases file handles before os.rename (especially on Windows).
    reaper.Main_OnCommand(40440, 0) -- All media offline
    for _, file in ipairs(files) do
      if file.old ~= file.new then
        if exists(file.new) then fail("La destination existe déjà : " .. file.new) end
        local success, why = os.rename(file.old, file.new)
        if not success then fail("Renommage impossible : " .. file.old .. "\n" .. tostring(why)) end
        renamed[#renamed + 1] = file
      end
    end
    for _, item in ipairs(items) do
      if not reaper.SetItemStateChunk(item.item, item.updated, false) then fail("Impossible de mettre à jour un item.") end
      for _, take in ipairs(item.takes) do
        if not reaper.GetSetMediaItemTakeInfo_String(reaper.GetTake(item.item, take.index), "P_NAME", take.name, true) then
          fail("Impossible de renommer une prise.")
        end
      end
    end
  end, function(message) return tostring(message) end)
  if not ok then
    reaper.Main_OnCommand(40440, 0)
    local errors = {}
    for i = #renamed, 1, -1 do
      local file = renamed[i]
      local restored, why
      if exists(file.old) then restored, why = false, "l'ancien chemin est occupé"
      else restored, why = os.rename(file.new, file.old) end
      if not restored then errors[#errors + 1] = file.new .. " : " .. tostring(why) end
    end
    for _, item in ipairs(items) do
      if not reaper.SetItemStateChunk(item.item, item.original, false) then errors[#errors + 1] = "Restauration d'un item impossible" end
    end
    if #errors > 0 then err = err .. "\n\nRestauration incomplète :\n" .. table.concat(errors, "\n") end
  end
  reaper.Main_OnCommand(40441, 0) -- All media online
  reaper.Undo_EndBlock2(project, TITLE .. " (fichiers sur disque : utiliser le CSV inverse)", -1)
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  if not ok then fail(err .. "\n\nSauvegarde : " .. backup .. "\nCSV inverse : " .. reverse) end
  reaper.Main_SaveProject(project, false)
  local status = reaper.IsProjectDirty(project) == 0 and "Projet enregistré." or "Enregistre le projet manuellement : la sauvegarde finale a échoué."
  reaper.ShowMessageBox(string.format("Terminé : %d fichiers et %d prises.\n%s\n\nSauvegarde :\n%s\n\nPour revenir aux anciens noms, relance le script avec :\n%s\n\nN'utilise pas Ctrl+Z pour annuler le renommage des fichiers.", #files, take_count, status, backup, reverse), TITLE, 0)
end

local ok, err = xpcall(main, function(message) return tostring(message) end)
if not ok then reaper.ShowMessageBox(err, TITLE, 0) end
