local runtimes = daukle.require("lib/runtimes")
local scripts = daukle.require("lib/scripts")
local links = daukle.require("lib/links")

local KNOWN_KEYS = { version = true, entry = true, packages = true, devPackages = true,
                     scripts = true, type = true }

local function config_of(context)
  if context.toolchain ~= nil then return context.toolchain.config end
  return context.config
end

local function reject_unknown_keys(config)
  for key in pairs(config) do
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

local function checked_packages(config, key)
  local packages = config[key]
  if packages == nil then return {} end
  if type(packages) ~= "table" then
    error('"' .. key .. '" must be a table of package name to version range, not a '
          .. type(packages), 0)
  end
  if #packages > 0 then
    error('"' .. key .. '" must be a table of package name to version range, not a list:'
          .. ' a list says nothing about which version of a package is wanted', 0)
  end
  local names = {}
  for name, range in pairs(packages) do
    local problem = package_name_problem(name)
    if problem ~= nil then error(problem, 0) end
    checked_range(name, range, key)
    names[#names + 1] = name
  end
  table.sort(names)
  return names, packages
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
local function package_json(spec)
  local type_line = spec.type == nil and "" or ('  "type": "' .. spec.type .. '",\n')
  return '{\n'
    .. '  "' .. links.MARKER_KEY .. '": "' .. links.MARKER_TEXT .. '",\n'
    .. type_line
    .. '  "private": true,\n'
    .. '  "dependencies": ' .. json_object(spec.packages, spec.package_ranges, "  ") .. ',\n'
    .. '  "devDependencies": ' .. json_object(spec.dev_packages, spec.dev_ranges, "  ") .. '\n'
    .. '}\n'
end

local function read(context)
  local config = config_of(context)
  reject_unknown_keys(config)
  local packages, package_ranges = checked_packages(config, "packages")
  local dev_packages, dev_ranges = checked_packages(config, "devPackages")
  local declared_scripts = scripts.read(config)
  return {
    version = version_of(context),
    entry = entry_of(config),
    type = type_of(config),
    scripts = declared_scripts,
    packages = packages,
    package_ranges = package_ranges,
    dev_packages = dev_packages,
    dev_ranges = dev_ranges,
  }
end

return {
  read = read,
  package_json = package_json,
  package_name_problem = package_name_problem,
  is_project_path = is_project_path,
}
