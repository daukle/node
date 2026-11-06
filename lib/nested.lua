--- `nestedPackages`: a `package.json` below the package root that marks a module format boundary
--- (D-247) or is a subpath shim of `main`, `module` and `types` (D-248), said in daukle.toml and
--- placed by node:install as a marked copy.
local links = daukle.require("lib/links")
local package_fields = daukle.require("lib/package_fields")

local nested = {}

nested.KEY = "nestedPackages"

--- The derived file naming each placement, directory to the bytes node:install writes there.
nested.PLACEMENTS_NAME = links.NESTED_NAME

local TYPES = { module = true, commonjs = true }

--- The entry points a shim declares, in the order a placement writes them.
local ENTRY_FIELDS = { "main", "module", "types" }

local IS_ENTRY_FIELD = { main = true, module = true, types = true }

--- The metadata a placement carries as JSON text, so a packed copy equals the original by value.
local FIELDS_KEY = package_fields.KEY

local SEGMENT = "^[%w%._%-@+]+$"

--- Why `directory` cannot hold a placed package.json, or nil when it can.
---
--- @implNote `node_modules` and the derived tree are refused because node:install owns them, and a
--- segment holding ".." anywhere because core refuses to read such a path at all.
local function directory_problem(directory)
  if type(directory) ~= "string" or directory == "" then return "is not a directory path" end
  for segment in string.gmatch(directory .. "/", "([^/]*)/") do
    if segment == "" or segment == "." or string.find(segment, "..", 1, true) or string.match(segment, SEGMENT) == nil then
      return "is not a relative path below the package root, written with \"/\""
    end
    if segment == "node_modules" then return "is inside node_modules, which node:install places" end
  end
  if directory == "build" or string.sub(directory, 1, 12) == "build/daukle" then
    return "is inside the derived build/daukle tree"
  end
  return nil
end

local function is_entry_path(value)
  return type(value) == "string" and value ~= "" and not string.find(value, "[%c\\]")
end

local function checked_metadata(label, fields)
  if type(fields) ~= "table" or #fields > 0 then
    error(label .. "." .. FIELDS_KEY .. " must be a table of field name to its JSON text", 0)
  end
  local names = {}
  for name, text in pairs(fields) do
    if not package_fields.METADATA[name] then
      error(label .. "." .. FIELDS_KEY .. ' names "' .. tostring(name)
            .. '": a placed package.json carries only metadata such as "name" there', 0)
    end
    if type(text) ~= "string" or not package_fields.is_json_value(text) then
      error(label .. "." .. FIELDS_KEY .. "." .. name .. " must be one JSON value as text, such as '\"shim\"'", 0)
    end
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

local function check_field(label, field, value)
  if field == "type" then
    if not TYPES[value] then
      error(label .. '.type is "module" or "commonjs", as in package.json, not "' .. tostring(value) .. '"', 0)
    end
  elseif IS_ENTRY_FIELD[field] then
    if not is_entry_path(value) then
      error(label .. "." .. field .. " must be a file path written with \"/\", as in package.json", 0)
    end
  elseif field ~= FIELDS_KEY then
    error(label .. ' declares "' .. tostring(field) .. '": a placed package.json carries only "type", '
          .. '"main", "module", "types" and ' .. FIELDS_KEY, 0)
  end
end

local function checked_entry(directory, entry)
  local label = '"' .. nested.KEY .. "." .. tostring(directory) .. '"'
  local problem = directory_problem(directory)
  if problem ~= nil then error(label .. " " .. problem, 0) end
  if type(entry) ~= "table" or #entry > 0 then
    error(label .. ' must be a table of the fields its package.json declares, such as { type = "commonjs" }', 0)
  end
  for field, value in pairs(entry) do check_field(label, field, value) end
  local metadata = entry[FIELDS_KEY] or {}
  return { directory = directory, type = entry.type, main = entry.main, module = entry.module,
           types = entry.types, metadata = metadata, metadata_names = checked_metadata(label, metadata) }
end

--- The checked placements, sorted by directory: `{ directory, type }`, `type` possibly nil.
function nested.read(config)
  local value = config[nested.KEY]
  if value == nil then return {} end
  if type(value) ~= "table" or #value > 0 then
    error('"' .. nested.KEY .. '" must be a table of directory to its package.json fields', 0)
  end
  local out = {}
  for directory, entry in pairs(value) do out[#out + 1] = checked_entry(directory, entry) end
  table.sort(out, function(left, right) return left.directory < right.directory end)
  return out
end

local function json_string(text)
  return '"' .. string.gsub(text, '[\\"\n]', { ["\\"] = "\\\\", ['"'] = '\\"', ["\n"] = "\\n" }) .. '"'
end

local function package_json(placement)
  local members = { json_string(links.MARKER_KEY) .. ": " .. json_string(links.MARKER_TEXT) }
  if placement.type ~= nil then members[#members + 1] = '"type": ' .. json_string(placement.type) end
  for _, field in ipairs(ENTRY_FIELDS) do
    if placement[field] ~= nil then members[#members + 1] = json_string(field) .. ": " .. json_string(placement[field]) end
  end
  for _, name in ipairs(placement.metadata_names) do
    members[#members + 1] = json_string(name) .. ": " .. placement.metadata[name]
  end
  return "{\n  " .. table.concat(members, ",\n  ") .. "\n}\n"
end

--- The placements file: always written, so a placement removed from daukle.toml is pruned.
function nested.placements_json(placements)
  local members = {}
  for index, placement in ipairs(placements) do
    members[index] = "  " .. json_string(placement.directory) .. ": " .. json_string(package_json(placement))
  end
  if #members == 0 then return "{}\n" end
  return "{\n" .. table.concat(members, ",\n") .. "\n}\n"
end

local BOM = "\239\187\191"

--- The entry a nested package.json translates to, or nil when it is a package of its own: only
--- `type`, `main`, `module` and `types`, beside metadata carried as its JSON text.
function nested.boundary_of(text)
  if string.sub(text, 1, 3) == BOM then text = string.sub(text, 4) end
  if string.match(text, "^%s*{") == nil then return nil end
  local parsed = daukle.json_parse(text)
  local raw = package_fields.raw_members(text)
  local entry, metadata = {}, {}
  for field, value in pairs(parsed) do
    if field == "type" then
      if not TYPES[value] then return nil end
      entry.type = value
    elseif IS_ENTRY_FIELD[field] then
      if not is_entry_path(value) then return nil end
      entry[field] = value
    elseif package_fields.METADATA[field] and raw[field] ~= nil then
      metadata[field] = raw[field]
    else
      return nil
    end
  end
  if next(metadata) ~= nil then entry[FIELDS_KEY] = metadata end
  return entry
end

nested.directory_problem = directory_problem

return nested
