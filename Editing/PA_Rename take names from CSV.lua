-- @description Rename take names from CSV (keep source files unchanged)
-- @author lepierrealain
-- @version 1.0
-- @about
--   Reads old_name,new_name from a UTF-8 CSV (comma or semicolon).
--   Matches source filenames, including section/reversed sources; falls back
--   to the current take name. Renames all matching takes in the current project.
--   Does not rename, move or relink files. Changes can be undone with Ctrl+Z.

local TITLE = "Renommer les noms d'items depuis un CSV"
local WINDOWS = reaper.GetOS():match("Win") ~= nil
local function key(value) return WINDOWS and value:lower() or value end
local function basename(path) return path:match("[^/\\]+$") or path end

local function parseCSV(data)
  data = data:gsub("^\239\187\191", "")
  local header = data:match("[^\r\n]*") or ""
  local delimiter = header:find(";", 1, true) and ";" or ","
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
      if not c:match("%s") then error("CSV mal formé après un guillemet.", 0) end
    elseif c == '"' then error("CSV mal formé : guillemet inattendu.", 0)
    else field[#field + 1] = c end
    i = i + 1
  end
  if quoted then error("CSV mal formé : guillemet non fermé.", 0) end
  if #field > 0 or #row > 0 or after_quote then line() end
  return rows
end

local function main()
  local chosen, path = reaper.GetUserFileNameForRead("K:\\Foley_renamed\\rename_map_updated.csv", TITLE, "csv")
  if not chosen then return end
  local file, why = io.open(path, "rb")
  if not file then error("Impossible de lire le CSV : " .. tostring(why), 0) end
  local data = file:read("*a"); file:close()
  local rows, columns = parseCSV(data), {}
  for i, name in ipairs(rows[1] or {}) do columns[name:match("^%s*(.-)%s*$"):lower()] = i end
  if not columns.old_name or not columns.new_name then error("Colonnes requises : old_name et new_name.", 0) end
  local map, total = {}, 0
  for i = 2, #rows do
    local old, new = rows[i][columns.old_name], rows[i][columns.new_name]
    if not old or not new or old == "" or new == "" or old:find("%c") or new:find("%c") then
      error("Nom vide ou invalide à la ligne " .. i .. ".", 0)
    end
    if map[key(old)] then error("Ancien nom en double : " .. old, 0) end
    map[key(old)] = {old = old, new = new}; total = total + 1
  end
  local project = reaper.EnumProjects(-1, "")
  local changes, used = {}, {}
  for i = 0, reaper.CountMediaItems(project) - 1 do
    local item = reaper.GetMediaItem(project, i)
    for t = 0, reaper.CountTakes(item) - 1 do
      local take = reaper.GetTake(item, t)
      local source = reaper.GetMediaItemTake_Source(take)
      local entry
      if source then
        while reaper.GetMediaSourceParent(source) do source = reaper.GetMediaSourceParent(source) end
        entry = map[key(basename(reaper.GetMediaSourceFileName(source)))]
      end
      local _, name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
      entry = entry or map[key(name)]
      if entry then
        used[key(entry.old)] = true
        if name ~= entry.new then changes[#changes + 1] = {take = take, old = name, new = entry.new} end
      end
    end
  end
  local matched = 0
  for _ in pairs(used) do matched = matched + 1 end
  if #changes == 0 then
    reaper.ShowMessageBox(matched > 0 and "Les prises correspondantes portent déjà les nouveaux noms." or "Aucun ancien nom du CSV ne correspond aux sources ou aux noms de prises du projet.", TITLE, 0)
    return
  end
  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock2(project)
  local ok, err = xpcall(function()
    for _, change in ipairs(changes) do
      if not reaper.GetSetMediaItemTakeInfo_String(change.take, "P_NAME", change.new, true) then
        error("Impossible de renommer une prise.", 0)
      end
    end
  end, tostring)
  if not ok then
    local restored = true
    for _, change in ipairs(changes) do
      if not reaper.GetSetMediaItemTakeInfo_String(change.take, "P_NAME", change.old, true) then restored = false end
    end
    if not restored then err = err .. "\nRestauration incomplète : utilise Ctrl+Z." end
  end
  reaper.Undo_EndBlock2(project, TITLE, -1)
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  if not ok then error(err, 0) end
  reaper.ShowMessageBox(string.format("%d prises renommées dans le projet (avec l'extension).\n%d lignes du CSV sans correspondance.\n\nLes fichiers restent inchangés. Ctrl+Z permet d'annuler.", #changes, total - matched), TITLE, 0)
end

local ok, err = xpcall(main, tostring)
if not ok then reaper.ShowMessageBox(err, TITLE, 0) end
