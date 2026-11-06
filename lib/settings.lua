local runtimes = daukle.require("lib/runtimes")
local scripts = daukle.require("lib/scripts")
local links = daukle.require("lib/links")
local package_fields = daukle.require("lib/package_fields")
local pins = daukle.require("lib/pins")
local published = daukle.require("lib/published")

local KNOWN_KEYS = { version = true, entry = true, scripts = true, type = true,
                     [package_fields.KEY] = true, [pins.KEY] = true, [published.KEY] = true }

local MOVED_TO_NPM = { packages = true, devPackages = true }

--- The fields the generated package.json writes itself, which `packageFields` cannot name.
local WRITTEN = { [links.MARKER_KEY] = true, type = true, private = true, dependencies = true,
                  devDependencies = true }

local function config_of(context)
  if context.toolchain ~= nil then return context.toolchain.config end
  return context.config
end

local function reject_unknown_keys(config)
  for key in pairs(config) do
    if MOVED_TO_NPM[key] then
      error(string.format('"%s" moved to [toolchains.npm] in daukle/node 4, where daukle/npm pins'
                          .. ' the closure it resolves to: an install resolves no range', key), 0)
    end
    if KNOWN_KEYS[key] == nil then
      error(string.format('"%s" is not a key this toolchain knows: a misspelled key would'
                          .. ' otherwise be ignored and build the wrong thing silently', key), 0)
    end
  end
end

local function version_of(context)
  local version = (context.toolchain ~= nil and context.toolchain.version)
                  or config_of(context).version
  if version == nil then
    error('a node toolchain needs a "version": which node to provision is not inferred, and'
          .. ' the resolver this toolchain generates does not work below ' .. runtimes.floor, 0)
  end
  return version
end

local function climbs_out(path)
  if string.match(path, "^/") ~= nil or string.match(path, "^%a:") ~= nil then return true end
  if string.find(path, "\\", 1, true) ~= nil then return true end
  if path == ".." or string.match(path, "^%.%./") ~= nil then return true end
  return string.find(path, "/../", 1, true) ~= nil or string.match(path, "/%.%.$") ~= nil
end

local function is_project_path(path)
  return path ~= "" and not climbs_out(path)
end

local function entry_of(config)
  local entry = config.entry
  if entry == nil then return nil end
  if type(entry) ~= "string" then
    error('"entry" must name a module as a path string, not a ' .. type(entry), 0)
  end
  if not is_project_path(entry) then
    error(string.format('"entry" must name a module inside the project, and "%s" does not', entry), 0)
  end
  return entry
end

local TYPES = { module = true, commonjs = true }

local function type_of(config)
  local value = config.type
  if value == nil then return nil end
  if type(value) ~= "string" or not TYPES[value] then
    error(string.format('"type" is "module" or "commonjs", as in package.json, not "%s"',
                        tostring(value)), 0)
  end
  return value
end

local SCOPED = "^@[%w][%w%.%_%-]*/[%w][%w%.%_%-]*$"
local PLAIN = "^[%w][%w%.%_%-]*$"

local function package_name_problem(name)
  if type(name) ~= "string"
     or (string.match(name, PLAIN) == nil and string.match(name, SCOPED) == nil) then
    return string.format('"%s" is not an npm package name: a name is "lodash" or "@scope/name"',
                         tostring(name))
  end
  return nil
end

--[[ @implNote the generated package.json is written without a json escaper, so
     what could need escaping is refused at the edge instead. Every npm name and
     every range a user can mean is inside this set; a value outside it would
     otherwise produce a file npm parses as something else. ]]
local function checked_range(name, range, key)
  if type(range) ~= "string" then
    error(string.format('%s."%s" must be a version range as a string, not a %s',
                        key, name, type(range)), 0)
  end
  if range == "" then
    error(string.format('%s."%s" is empty, and npm has no empty range', key, name), 0)
  end
  if string.match(range, '^[%w%s%.%-%+%*|<>=~^%(%)/:#@]+$') == nil then
    error(string.format('%s."%s" is not a version range this toolchain writes: "%s" holds a'
                        .. ' character that would have to be escaped into the generated'
                        .. ' package.json', key, name, range), 0)
  end
  return range
end

local function checked_ranges(names, ranges, key)
  for index = 1, #names do
    local problem = package_name_problem(names[index])
    if problem ~= nil then error(problem, 0) end
    checked_range(names[index], ranges[names[index]], key)
  end
end

local function json_object(names, packages, indent)
  if #names == 0 then return "{}" end
  local body = ""
  for index = 1, #names do
    local separator = index == #names and "\n" or ",\n"
    body = body .. indent .. '  "' .. names[index] .. '": "' .. packages[names[index]] .. '"'
            .. separator
  end
  return "{\n" .. body .. indent .. "}"
end

--[[ No "name": the project did not choose one and a generated name would show
     up in npm's output as if it had. "private" is what stops npm asking for the
     name and the version a publishable package needs. ]]
--- The carried fields, each written as `"name": <its JSON text>` after a separator.
local function carried_fields(names, values)
  local text = ""
  for _, name in ipairs(names or {}) do text = text .. ',\n  "' .. name .. '": ' .. values[name] end
  return text
end

local function package_json(spec)
  local type_line = spec.type == nil and "" or ('  "type": "' .. spec.type .. '",\n')
  return '{\n'
    .. '  "' .. links.MARKER_KEY .. '": "' .. links.MARKER_TEXT .. '",\n'
    .. type_line
    .. '  "private": true,\n'
    .. '  "dependencies": ' .. json_object(spec.packages, spec.package_ranges, "  ") .. ',\n'
    .. '  "devDependencies": ' .. json_object(spec.dev_packages, spec.dev_ranges, "  ")
    .. carried_fields(spec.field_names, spec.fields) .. '\n'
    .. '}\n'
end

--- The consumer-facing fields `node:pack` publishes, or nil when the package is not packed.
local function published_of(config)
  local value = config[published.KEY]
  if value == nil then return nil end
  if type(value) ~= "table" then
    error('"' .. published.KEY .. '" must be a table of field name to its JSON text, not a ' .. type(value), 0)
  end
  for name, text in pairs(value) do
    local label = '"' .. published.KEY .. "." .. tostring(name) .. '"'
    if not published.FIELDS[name] then
      error(label .. " is not a field this table publishes: it holds the name, version, metadata,"
            .. ' "main" and "files", and every other field has a key of its own', 0)
    end
    if type(text) ~= "string" or not package_fields.is_json_value(text) then
      error(label .. " must be one JSON value as text, such as '\"1.0.0\"'", 0)
    end
  end
  if value.name == nil or value.version == nil then
    error('"' .. published.KEY .. '" needs a "name" and a "version", which npm pack names the tarball by', 0)
  end
  return value
end

local function read(context)
  local config = config_of(context)
  reject_unknown_keys(config)
  local pinned = pins.read(config) or { packages = {}, package_ranges = {}, dev_packages = {},
                                         dev_ranges = {} }
  checked_ranges(pinned.packages, pinned.package_ranges, "dependencies")
  checked_ranges(pinned.dev_packages, pinned.dev_ranges, "devDependencies")
  local declared_scripts = scripts.read(config)
  local field_names, fields = package_fields.checked(config, WRITTEN)
  return {
    field_names = field_names,
    fields = fields,
    version = version_of(context),
    entry = entry_of(config),
    type = type_of(config),
    scripts = declared_scripts,
    packages = pinned.packages,
    package_ranges = pinned.package_ranges,
    dev_packages = pinned.dev_packages,
    dev_ranges = pinned.dev_ranges,
    lock = pinned.text ~= nil and pinned or nil,
    published = published_of(config),
  }
end

return {
  read = read,
  package_json = package_json,
  package_name_problem = package_name_problem,
  is_project_path = is_project_path,
}
