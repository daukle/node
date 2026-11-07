local glob = daukle.require("lib/glob")

--- A `pnpm-workspace.yaml`, read in the few shapes a workspace's members and catalogs take, and
--- its `packages` globs matched against a project's directories as pnpm matches them.
---
--- @implNote a restricted reader rather than a YAML parser: a line outside these shapes raises,
--- naming it, so a construct it does not know is never misread as one it does.
local pnpm_workspace = {}

pnpm_workspace.NAME = "pnpm-workspace.yaml"
pnpm_workspace.KEY = "workspace"

local BOM = "\239\187\191"

local function unreadable(number, line)
  return string.format('line %d, "%s", is not a shape this toolchain reads: a list of `packages` globs,'
                       .. ' a `catalog` map, or a `catalogs` map of maps', number, line)
end

local function single_quoted(text)
  local value, index = {}, 2
  while index <= #text do
    local character = string.sub(text, index, index)
    if character ~= "'" then
      value[#value + 1] = character
      index = index + 1
    elseif string.sub(text, index + 1, index + 1) == "'" then
      value[#value + 1] = "'"
      index = index + 2
    else
      return table.concat(value), string.sub(text, index + 1)
    end
  end
  return nil
end

--- @implNote a backslash is refused rather than unescaped: no glob, name or range needs one.
local function double_quoted(text)
  local finish = string.find(text, '"', 2, true)
  if finish == nil then return nil end
  local value = string.sub(text, 2, finish - 1)
  if string.find(value, "\\", 1, true) then return nil end
  return value, string.sub(text, finish + 1)
end

--- A quoted scalar at the start of `text` and what follows it, or nil when `text` holds none.
local function quoted(text)
  local quote = string.sub(text, 1, 1)
  if quote == "'" then return single_quoted(text) end
  if quote == '"' then return double_quoted(text) end
  return nil
end

local function is_line_end(rest)
  return string.match(rest, "^%s*$") ~= nil or string.match(rest, "^%s+#") ~= nil
end

--- The scalar a line ends with, quoted or bare, its trailing comment dropped; nil when malformed.
local function value_of(text)
  if string.match(text, "^['\"]") then
    local value, rest = quoted(text)
    if value == nil or not is_line_end(rest) then return nil end
    return value
  end
  local bare = string.match(string.gsub(text, "%s+#.*$", ""), "^(.-)%s*$")
  if bare == "" or string.match(bare, "^[%[{&*|>!%%@`#]") then return nil end
  if string.sub(bare, -1) == ":" or string.find(bare, ": ", 1, true) then return nil end
  return bare
end

--- A mapping key at the start of `text` and what follows its colon, or nil when there is none.
local function key_of(text)
  if string.match(text, "^['\"]") then
    local key, rest = quoted(text)
    if key == nil or string.sub(rest, 1, 1) ~= ":" then return nil end
    return key, string.sub(rest, 2)
  end
  return string.match(text, "^([^:%s'\"#]+):(.*)$")
end

--- A `key: value` entry, or nil when the line is not one.
local function entry_of(text)
  local key, rest = key_of(text)
  if key == nil or string.match(rest, "^%s") == nil then return nil end
  local value = value_of(string.match(rest, "^%s*(.-)$"))
  if value == nil then return nil end
  return key, value
end

local function is_heading(rest)
  return is_line_end(rest) or string.match(rest, "^#") ~= nil
end

local function add_glob(workspace, text)
  if string.sub(text, 1, 1) == "!" then
    workspace.excluded[#workspace.excluded + 1] = string.sub(text, 2)
  else
    workspace.packages[#workspace.packages + 1] = text
  end
end

local function flow_globs(text)
  local body = string.match(text, "^%[(.*)%]%s*$") or string.match(text, "^%[(.*)%]%s+#.*$")
  if body == nil or string.find(body, "[%[%]{}]") then return nil end
  local globs = {}
  for item in string.gmatch(body, "[^,]+") do
    local value = value_of(string.match(item, "^%s*(.-)%s*$"))
    if value == nil then return nil end
    globs[#globs + 1] = value
  end
  return globs
end

--- Reads one unindented line into `workspace`, returning false when it is not a shape this reads.
local function read_top_level(workspace, state, line)
  local key, rest = key_of(line)
  if key == nil then return false end
  state.catalog_name = nil
  if key == "packages" then
    state.section = "packages"
    if is_heading(rest) then return true end
    local globs = flow_globs(string.match(rest, "^%s*(.-)$"))
    if globs == nil then return false end
    for _, text in ipairs(globs) do add_glob(workspace, text) end
    state.section = nil
  elseif key == "catalog" or key == "catalogs" then
    if not is_heading(rest) then return false end
    state.section = key
    workspace[key] = workspace[key] or {}
  else
    workspace.unknown[#workspace.unknown + 1] = key
    state.section = "unknown"
  end
  return true
end

local function read_package_glob(workspace, line)
  local item = string.match(line, "^%s*%-%s+(.-)$")
  local value = item and value_of(item)
  if value == nil then return false end
  add_glob(workspace, value)
  return true
end

local function read_catalog_entry(catalog, body)
  local name, range = entry_of(body)
  if name == nil then return false end
  catalog[name] = range
  return true
end

--- Reads one indented line into the section it belongs to, returning false when it is not one.
local function read_nested(workspace, state, line)
  local section = state.section
  if section == "unknown" then return true end
  if section == "packages" then return read_package_glob(workspace, line) end
  local indent = #string.match(line, "^( *)")
  local body = string.sub(line, indent + 1)
  if section == "catalog" and indent == 2 then return read_catalog_entry(workspace.catalog, body) end
  if section == "catalogs" and indent == 2 then
    local name, rest = key_of(body)
    if name == nil or not is_heading(rest) then return false end
    state.catalog_name = name
    workspace.catalogs[name] = workspace.catalogs[name] or {}
    return true
  end
  if section == "catalogs" and indent == 4 and state.catalog_name ~= nil then
    return read_catalog_entry(workspace.catalogs[state.catalog_name], body)
  end
  return false
end

local function is_blank(line)
  return string.match(line, "^%s*$") ~= nil or string.match(line, "^%s*#") ~= nil
end

local function read_line(workspace, state, line)
  if string.match(line, "^[ ]*\t") then return false end
  if is_blank(line) then return true end
  if string.match(line, "^%-%s") and state.section == "unknown" then return true end
  if string.match(line, "^%-%s") and state.section == "packages" then return read_package_glob(workspace, line) end
  if string.match(line, "^%s") == nil then return read_top_level(workspace, state, line) end
  return state.section ~= nil and read_nested(workspace, state, line)
end

--- The workspace a file declares, or nil and why when a line is outside the shapes it reads.
function pnpm_workspace.parse(text)
  if string.sub(text, 1, 3) == BOM then text = string.sub(text, 4) end
  local workspace = { packages = {}, excluded = {}, unknown = {} }
  local state, number = {}, 0
  for raw in string.gmatch(text .. "\n", "([^\n]*)\n") do
    number = number + 1
    local line = string.gsub(raw, "\r$", "")
    if not read_line(workspace, state, line) then return nil, unreadable(number, line) end
  end
  return workspace
end

function pnpm_workspace.read(text)
  local workspace, problem = pnpm_workspace.parse(text)
  if workspace == nil then error(problem, 0) end
  return workspace
end

local function normalized(pattern)
  while string.sub(pattern, 1, 2) == "./" do pattern = string.sub(pattern, 3) end
  return pattern
end

local function matches_any(patterns, directory)
  for _, pattern in ipairs(patterns or {}) do
    if glob.matches(normalized(pattern), directory) then return true end
  end
  return false
end

--- The segments pnpm never finds a member below, `@pnpm/fs.find-packages`'s `DEFAULT_IGNORE`.
local IGNORED_SEGMENTS = { node_modules = true, bower_components = true, test = true, tests = true }

local function is_ignored(directory)
  for segment in string.gmatch(directory, "[^/]+") do
    if IGNORED_SEGMENTS[segment] then return true end
  end
  return false
end

--- Each `packages` glob, `!` included, that holds a brace set, which pnpm expands and this does not.
function pnpm_workspace.brace_globs(workspace)
  local found = {}
  for _, pattern in ipairs(workspace.packages or {}) do
    if string.find(pattern, "{", 1, true) then found[#found + 1] = pattern end
  end
  for _, pattern in ipairs(workspace.excluded or {}) do
    if string.find(pattern, "{", 1, true) then found[#found + 1] = "!" .. pattern end
  end
  return found
end

function pnpm_workspace.members(workspace, directories)
  local members = {}
  for _, directory in ipairs(directories) do
    if matches_any(workspace.packages, directory) and not matches_any(workspace.excluded, directory)
       and not is_ignored(directory) then
      members[#members + 1] = directory
    end
  end
  table.sort(members)
  return members
end

local function quoted_scalar(text)
  return "'" .. string.gsub(text, "'", "''") .. "'"
end

local function sorted_keys(map)
  local keys = {}
  for key in pairs(map) do keys[#keys + 1] = key end
  table.sort(keys)
  return keys
end

local function render_catalog(lines, catalog, indent)
  for _, name in ipairs(sorted_keys(catalog)) do
    lines[#lines + 1] = indent .. quoted_scalar(name) .. ": " .. quoted_scalar(catalog[name])
  end
end

--- The `pnpm-workspace.yaml` a `{ members, catalog, catalogs }` renders to: each member, a
--- `{ dir }`, by its directory, then the catalogs, in the shapes `parse` reads back.
function pnpm_workspace.render(workspace)
  local lines = { #workspace.members == 0 and "packages: []" or "packages:" }
  for _, member in ipairs(workspace.members) do lines[#lines + 1] = "  - " .. quoted_scalar(member.dir) end
  if workspace.catalog ~= nil then
    lines[#lines + 1] = "catalog:"
    render_catalog(lines, workspace.catalog, "  ")
  end
  if workspace.catalogs ~= nil then
    lines[#lines + 1] = "catalogs:"
    for _, name in ipairs(sorted_keys(workspace.catalogs)) do
      lines[#lines + 1] = "  " .. quoted_scalar(name) .. ":"
      render_catalog(lines, workspace.catalogs[name], "    ")
    end
  end
  return table.concat(lines, "\n") .. "\n"
end

return pnpm_workspace
