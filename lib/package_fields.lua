--- Which `package.json` fields daukle/node models, writes or has no equivalent
--- for, and the rest, carried verbatim as `packageFields` (spec D-225, the
--- 2026-11-04 corpus backlog design, section 3).
local package_fields = {}

package_fields.KEY = "packageFields"

--- The surface rows the field tables name; translate's own map takes them from here.
package_fields.ROWS = {
  shell = "The boundary: what \"100% of npm and Node\" does not include",
  workspaces = "6. Workspaces: `workspaces`, each linked into the root `node_modules`",
}

--- Fields with no equivalent in this toolchain, each with its surface row.
package_fields.ABSENT = {
  peerDependencies = "3. Dependencies: `peerDependencies`",
  peerDependenciesMeta = "3. Dependencies: `peerDependenciesMeta`",
  optionalDependencies = "3. Dependencies: `optionalDependencies`",
  bundleDependencies = "3. Dependencies: `bundleDependencies`",
  bundledDependencies = "3. Dependencies: `bundleDependencies`",
  workspaces = package_fields.ROWS.workspaces,
  bin = "7. Packing and publishing: the project's own `bin`",
  imports = "2. Module resolution: the project's own `\"imports\"`, `#`-specifiers",
  publishConfig = "7. Packing and publishing: `publishConfig`",
  config = "5. Scripts: the `config` field",
  os = "3. Dependencies", cpu = "3. Dependencies",
  devEngines = "1. The runtime: `devEngines`",
  packageManager = package_fields.ROWS.shell,
}

--- Fields the migrator reads into keys of their own; `overrides` into daukle/npm's block (D-246).
---
--- @implNote `engines` is absent on purpose: it is read for `version` AND carried,
--- because what a package supports is not which node daukle runs (`AUTHORING.md`).
package_fields.READ = { dependencies = true, devDependencies = true, type = true,
                        main = true, exports = true, scripts = true, files = true, overrides = true }

--- Fields describing the package, which the generated file deliberately leaves out.
package_fields.METADATA = { name = true, version = true, description = true, license = true, author = true,
                            contributors = true, keywords = true, repository = true, homepage = true,
                            bugs = true, private = true, funding = true }

--- Whether a field is one daukle/node handles itself, so it is never carried.
function package_fields.is_owned(name, written)
  return package_fields.ABSENT[name] ~= nil or package_fields.READ[name] or package_fields.METADATA[name]
         or written[name] == true
end

local function skip_blank(text, index)
  return string.match(text, "^[ \t\r\n]*()", index)
end

--- The index just past the JSON string starting at `index`, a `"`, or nil when it never ends.
local function after_string(text, index)
  index = index + 1
  while index <= #text do
    local character = string.sub(text, index, index)
    if character == "\\" then
      index = index + 2
    elseif character == '"' then
      return index + 1
    else
      index = index + 1
    end
  end
  return nil
end

--- The index just past the JSON value starting at `index`, or nil when it never ends.
local function after_value(text, index)
  local first = string.sub(text, index, index)
  if first == '"' then return after_string(text, index) end
  if first ~= "{" and first ~= "[" then
    return string.match(text, "^[^,}%]%s]*()", index)
  end
  local depth = 0
  while index <= #text do
    local character = string.sub(text, index, index)
    if character == '"' then
      index = after_string(text, index)
      if index == nil then return nil end
    else
      if character == "{" or character == "[" then depth = depth + 1 end
      if character == "}" or character == "]" then depth = depth - 1 end
      index = index + 1
      if depth == 0 then return index end
    end
  end
  return nil
end

--- Each top-level member's value exactly as the file writes it, by name, for
--- names that hold no escape; a name with one is left out, so it keeps blocking.
---
--- @param text a package.json `daukle.json_parse` has already read, so every member ends
function package_fields.raw_members(text)
  local members = {}
  local index = skip_blank(text, 1)
  if string.sub(text, index, index) ~= "{" then return members end
  index = skip_blank(text, index + 1)
  while index <= #text and string.sub(text, index, index) == '"' do
    local name_end = after_string(text, index)
    local name = string.sub(text, index + 1, name_end - 2)
    index = skip_blank(text, name_end)
    index = skip_blank(text, index + 1)
    local value_end = after_value(text, index)
    if not string.find(name, "\\", 1, true) then members[name] = string.sub(text, index, value_end - 1) end
    index = skip_blank(text, value_end)
    if string.sub(text, index, index) == "," then index = skip_blank(text, index + 1) end
  end
  return members
end

--- Whether the text is exactly one value, checked before parsing so a refusal
--- can name the key: the sandbox has no pcall and `daukle.json_parse` raises.
---
--- @implNote `1, "dependencies": {}` would parse inside an object too, and add
--- a member to the generated file, which is why the whole text must be one value.
local function is_one_value(text)
  local start = skip_blank(text, 1)
  if start > #text then return false end
  local finish = after_value(text, start)
  return finish ~= nil and skip_blank(text, finish) == #text + 1
end

local function is_json_value(text)
  if not is_one_value(text) then return false end
  daukle.json_parse('{"v":' .. text .. "}")
  return true
end

package_fields.is_json_value = is_json_value

--- The checked fields, sorted by name, and their values.
function package_fields.checked(config, written)
  local value = config[package_fields.KEY]
  if value == nil then return {}, {} end
  if type(value) ~= "table" then
    error('"' .. package_fields.KEY .. '" must be a table of field name to its JSON text, not a ' .. type(value), 0)
  end
  local names = {}
  for name, text in pairs(value) do
    local label = '"' .. package_fields.KEY .. "." .. tostring(name) .. '"'
    if type(name) ~= "string" or string.find(name, '["\\%c]') then
      error(label .. " is not a field name this toolchain writes", 0)
    end
    if package_fields.is_owned(name, written) then
      error(label .. " is a field daukle/node handles itself, so it is not carried", 0)
    end
    if type(text) ~= "string" or not is_json_value(text) then
      error(label .. " must be one JSON value as text, such as '[\"> 1%\"]'", 0)
    end
    names[#names + 1] = name
  end
  table.sort(names)
  return names, value
end

return package_fields
