--- `nestedPackages`: a `package.json` below the package root that only marks a module format
--- boundary, said in daukle.toml and placed by node:install as a marked copy (D-247).
local links = daukle.require("lib/links")

local nested = {}

nested.KEY = "nestedPackages"

--- The derived file naming each placement, directory to the bytes node:install writes there.
nested.PLACEMENTS_NAME = links.NESTED_NAME

local TYPES = { module = true, commonjs = true }

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

local function checked_entry(directory, entry)
  local label = '"' .. nested.KEY .. "." .. tostring(directory) .. '"'
  local problem = directory_problem(directory)
  if problem ~= nil then error(label .. " " .. problem, 0) end
  if type(entry) ~= "table" or #entry > 0 then
    error(label .. ' must be a table of the fields its package.json declares, such as { type = "commonjs" }', 0)
  end
  for field, value in pairs(entry) do
    if field ~= "type" then
      error(label .. ' declares "' .. tostring(field) .. '": a placed package.json carries only "type"', 0)
    end
    if not TYPES[value] then
      error(label .. '.type is "module" or "commonjs", as in package.json, not "' .. tostring(value) .. '"', 0)
    end
  end
  return { directory = directory, type = entry.type }
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

local function package_json(placement)
  local type_line = placement.type == nil and "" or (',\n  "type": "' .. placement.type .. '"')
  return '{\n  "' .. links.MARKER_KEY .. '": "' .. links.MARKER_TEXT .. '"' .. type_line .. '\n}\n'
end

local function json_string(text)
  return '"' .. string.gsub(text, '[\\"\n]', { ["\\"] = "\\\\", ['"'] = '\\"', ["\n"] = "\\n" }) .. '"'
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

--- The entry a nested package.json translates to, or nil when it declares more than a format
--- boundary: only `type`, beside metadata node reads for nothing when there is no `exports`.
function nested.boundary_of(text, metadata)
  if string.sub(text, 1, 3) == BOM then text = string.sub(text, 4) end
  if string.match(text, "^%s*{") == nil then return nil end
  local parsed = daukle.json_parse(text)
  local entry = {}
  for field, value in pairs(parsed) do
    if field == "type" then
      if not TYPES[value] then return nil end
      entry.type = value
    elseif not metadata[field] then
      return nil
    end
  end
  return entry
end

nested.directory_problem = directory_problem

return nested
