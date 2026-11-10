local runtimes = daukle.require("lib/runtimes")
local scripts = daukle.require("lib/scripts")
local links = daukle.require("lib/links")
local package_fields = daukle.require("lib/package_fields")
local pins = daukle.require("lib/pins")
local pnpm_pins = daukle.require("lib/pnpm_pins")
local published = daukle.require("lib/published")
local nested = daukle.require("lib/nested")
local pnpm_workspace = daukle.require("lib/pnpm_workspace")

local KNOWN_KEYS = { version = true, entry = true, scripts = true, type = true,
                     [package_fields.KEY] = true, [pins.KEY] = true, [pnpm_pins.KEY] = true, [published.KEY] = true,
                     [nested.KEY] = true, [pnpm_workspace.KEY] = true }

local MOVED_TO_NPM = { packages = true, devPackages = true }

--- Keys a workspace member holds in its own block and any other package in its resolver's.
local RESOLVER_KEYS = { peerPackages = true, optionalPackages = true, peerPackagesMeta = true }

local WORKSPACE_PREFIXES = { "workspace:", "catalog:", "file:" }

--- The fields the generated package.json writes itself, which `packageFields` cannot name.
local WRITTEN = { [links.MARKER_KEY] = true, type = true, private = true, dependencies = true,
                  devDependencies = true }

local WRITTEN_WHEN_PACKED = { name = true, version = true }
for name in pairs(WRITTEN) do WRITTEN_WHEN_PACKED[name] = true end

local function config_of(context)
  if context.toolchain ~= nil then return context.toolchain.config end
  return context.config
end

--- Whether the block is a pnpm workspace member's, whose `workspace` names its root's instance.
local function is_workspace_member(config)
  return type(config[pnpm_workspace.KEY]) == "string"
end

--- @implNote a workspace member keeps its ranges in its own block, since the pins are the root's
--- alone and cover every member (spec 4.2).
local function reject_unknown_keys(config)
  for key in pairs(config) do
    if MOVED_TO_NPM[key] and not is_workspace_member(config) then
      error(string.format('"%s" moved to [toolchains.npm] in daukle/node 4, where daukle/npm pins'
                          .. ' the closure it resolves to: an install resolves no range', key), 0)
    end
    if RESOLVER_KEYS[key] and not is_workspace_member(config) then
      error(string.format('"%s" belongs in [toolchains.npm] or [toolchains.pnpm], which pin the closure'
                          .. ' it resolves to: an install resolves no range', key), 0)
    end
    if KNOWN_KEYS[key] == nil and not MOVED_TO_NPM[key] and not RESOLVER_KEYS[key] then
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
local function checked_range(name, range, key, in_workspace)
  if type(range) ~= "string" then
    error(string.format('%s."%s" must be a version range as a string, not a %s',
                        key, name, type(range)), 0)
  end
  if range == "" then
    error(string.format('%s."%s" is empty, and npm has no empty range', key, name), 0)
  end
  local lowered = string.lower(range)
  for _, prefix in ipairs(WORKSPACE_PREFIXES) do
    if not in_workspace and string.sub(lowered, 1, #prefix) == prefix then
      error(string.format('%s."%s" is "%s", which only pnpm resolves, inside a workspace: this block'
                          .. ' carries no "%s"', key, name, range, pnpm_workspace.KEY), 0)
    end
  end
  if string.match(range, '^[%w%s%.%-_%+%*|<>=~^%(%)/:#@]+$') == nil then
    error(string.format('%s."%s" is not a version range this toolchain writes: "%s" holds a'
                        .. ' character that would have to be escaped into the generated'
                        .. ' package.json', key, name, range), 0)
  end
  return range
end

local function checked_ranges(names, ranges, key, in_workspace)
  for index = 1, #names do
    local problem = package_name_problem(names[index])
    if problem ~= nil then error(problem, 0) end
    checked_range(names[index], ranges[names[index]], key, in_workspace)
  end
end

local function sorted_names(map)
  local names = {}
  for name in pairs(map) do names[#names + 1] = name end
  table.sort(names)
  return names
end

--- A workspace member's own ranges, checked: `packages`, `devPackages`, `peerPackages` and
--- `optionalPackages`, each a map, and `peerPackagesMeta`, one JSON value as text.
local function check_member_ranges(config)
  for _, pair in ipairs({ { "packages", "dependencies" }, { "devPackages", "devDependencies" },
                          { "peerPackages", "peerDependencies" }, { "optionalPackages", "optionalDependencies" } }) do
    local map = config[pair[1]]
    if map ~= nil then
      if type(map) ~= "table" then error('"' .. pair[1] .. '" must be a table of package name to range', 0) end
      checked_ranges(sorted_names(map), map, pair[2], true)
    end
  end
  local meta = config.peerPackagesMeta
  if meta ~= nil and (type(meta) ~= "string" or not package_fields.is_json_value(meta)) then
    error('"peerPackagesMeta" must be one JSON object as text', 0)
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

--- The carried fields, each written as `"name": <its JSON text>` after a separator.
local function carried_fields(names, values)
  local text = ""
  for _, name in ipairs(names or {}) do text = text .. ',\n  "' .. name .. '": ' .. values[name] end
  return text
end

--- A dependency map after a separator, or nothing for a field the package does not declare.
local function declared_ranges(field, names, ranges)
  if #names == 0 then return "" end
  return ',\n  "' .. field .. '": ' .. json_object(names, ranges, "  ")
end

--- The peer and optional fields, every one of which npm and pnpm compare with their lockfile.
local function peer_and_optional_fields(spec)
  return declared_ranges("peerDependencies", spec.peer_packages, spec.peer_ranges)
    .. declared_ranges("optionalDependencies", spec.optional_packages, spec.optional_ranges)
    .. (spec.peer_meta == nil and "" or (',\n  "peerDependenciesMeta": ' .. spec.peer_meta))
end

--- The JSON text of the name the package resolves itself by, or nil when it `exports` nothing.
local function own_name_of(spec)
  local packed = spec.published
  if packed == nil or packed.exports == nil then return nil end
  return packed.name
end

--- The packed package's `name` and `version`, which a program reads back from this file, and its
--- `exports`, by which node resolves the package's own name from inside it, as in the original.
---
--- @implNote "private" is what stops npm treating this file as the publishable manifest, which
--- `node:pack` renders apart.
local function packed_identity_fields(spec)
  local packed = spec.published
  if packed == nil then return "" end
  local fields = '  "name": ' .. packed.name .. ',\n  "version": ' .. packed.version .. ',\n'
  if packed.exports == nil then return fields end
  return fields .. '  "exports": ' .. packed.exports .. ',\n'
end

--- @implNote an offline `npm ci` checks each lockfile edge against the package.json beside it,
--- so an edge the pinned overrides changed asks the registry unless the overrides are here too;
--- pnpm reads its own from `pnpm.overrides` and refuses a frozen install when they differ.
local function overrides_field(spec)
  if spec.overrides == nil then return "" end
  if spec.pnpm_lock ~= nil and spec.fields ~= nil and spec.fields.pnpm ~= nil then
    error('this package carries a "pnpm" field and pnpm-pinned "overrides", which render as a second'
          .. ' "pnpm" key: write the overrides inside the "pnpm" field\'s own text instead', 0)
  end
  if spec.pnpm_lock ~= nil then return ',\n  "pnpm": { "overrides": ' .. spec.overrides .. ' }' end
  return ',\n  "overrides": ' .. spec.overrides
end

--- The pins of whichever resolver wrote them: daukle/npm's or daukle/pnpm's, never both.
local function pinned_of(config)
  local npm_pinned, pnpm_pinned = pins.read(config), pnpm_pins.read(config)
  if npm_pinned ~= nil and pnpm_pinned ~= nil then
    error("this toolchain carries both npm's and pnpm's pins, and a package root installs with one"
          .. " package manager: remove one of [toolchains.npm] and [toolchains.pnpm]", 0)
  end
  return npm_pinned or pnpm_pinned or { packages = {}, package_ranges = {}, dev_packages = {}, dev_ranges = {},
                                        peer_packages = {}, peer_ranges = {}, optional_packages = {}, optional_ranges = {} },
         pnpm_pinned
end

local function package_json(spec)
  local type_line = spec.type == nil and "" or ('  "type": "' .. spec.type .. '",\n')
  return '{\n'
    .. '  "' .. links.MARKER_KEY .. '": "' .. links.MARKER_TEXT .. '",\n'
    .. type_line
    .. packed_identity_fields(spec)
    .. '  "private": true,\n'
    .. '  "dependencies": ' .. json_object(spec.packages, spec.package_ranges, "  ") .. ',\n'
    .. '  "devDependencies": ' .. json_object(spec.dev_packages, spec.dev_ranges, "  ")
    .. peer_and_optional_fields(spec)
    .. overrides_field(spec)
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
    if not published.FIELDS[name] and name ~= published.SCRIPT_TEXT then
      error(label .. " is not a field this table publishes: it holds the name, version, metadata,"
            .. ' "main", "exports", "files", "publishConfig" and "packageManager", and every other field has a key of its own', 0)
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

local WORKSPACE_KEYS = { members = true, catalog = true, catalogs = true, settings = true }

local function is_instance_name(name)
  return string.match(name, "^[%w][%w%.%_%-]*$") ~= nil
end

local function workspace_problem(text)
  return '"' .. pnpm_workspace.KEY .. '" ' .. text
end

--- A catalog as read from daukle.toml: package name to range, each a one-line string.
local function checked_catalog(catalog, label)
  if type(catalog) ~= "table" then error(workspace_problem(label .. " must be a table of package name to range"), 0) end
  for name, range in pairs(catalog) do
    if type(name) ~= "string" or type(range) ~= "string" or string.find(name .. range, "%c") then
      error(workspace_problem(label .. '."' .. tostring(name) .. '" must be a range as a one-line string'), 0)
    end
  end
  return catalog
end

local function checked_workspace_settings(text)
  if text == nil then return nil end
  if type(text) ~= "string" then error(workspace_problem('"settings" must be workspace file text'), 0) end
  local problem = pnpm_workspace.settings_problem(text)
  if problem ~= nil then error(workspace_problem('"settings" ' .. problem), 0) end
  return text
end

--- A workspace root's `workspace`: its members, each `{ dir, instance }` sorted by the directory
--- below the root, its catalogs, and its settings as workspace file text.
local function workspace_of(config)
  local value = config[pnpm_workspace.KEY]
  if value == nil or type(value) == "string" then return nil end
  if type(value) ~= "table" then
    error(workspace_problem("is a member's root instance as a string, or a root's members and catalogs as a table"), 0)
  end
  for key in pairs(value) do
    if not WORKSPACE_KEYS[key] then error(workspace_problem('holds "' .. tostring(key) .. '", which is not "members", "catalog", "catalogs" or "settings"'), 0) end
  end
  if type(value.members) ~= "table" then
    error(workspace_problem('needs "members", each member\'s directory mapped to its instance'), 0)
  end
  local members = {}
  for _, directory in ipairs(sorted_names(value.members)) do
    local instance = value.members[directory]
    if type(directory) ~= "string" or not is_project_path(directory) or string.find(directory, "%c") then
      error(workspace_problem('"members" names "' .. tostring(directory) .. '", which is not a directory inside the project'), 0)
    end
    if type(instance) ~= "string" or not is_instance_name(instance) then
      error(workspace_problem('"members"."' .. directory .. '" is "' .. tostring(instance) .. '", which is not an instance name'), 0)
    end
    members[#members + 1] = { dir = directory, instance = instance }
  end
  local catalogs = nil
  if value.catalogs ~= nil then
    if type(value.catalogs) ~= "table" then error(workspace_problem('"catalogs" must be a table of catalog name to catalog'), 0) end
    catalogs = {}
    for name, catalog in pairs(value.catalogs) do catalogs[name] = checked_catalog(catalog, 'catalogs."' .. tostring(name) .. '"') end
  end
  return { members = members, catalog = value.catalog ~= nil and checked_catalog(value.catalog, "catalog") or nil,
           catalogs = catalogs, settings = checked_workspace_settings(value.settings) }
end

--- A member's `workspace`, the instance of the workspace root it installs through.
local function workspace_root_of(config)
  local value = config[pnpm_workspace.KEY]
  if type(value) ~= "string" then return nil end
  if not is_instance_name(value) then
    error(workspace_problem('names "' .. value .. '", which is not an instance name'), 0)
  end
  return value
end

--- A workspace member's own ranges, which its rendered package.json declares for pnpm to install.
local function member_packages(config, key)
  local map = config[key] or {}
  return sorted_names(map), map
end

--- @implNote a block carrying `workspace`, a root's or a member's, accepts `workspace:`, `catalog:`
--- and `file:` pins, which only pnpm resolves, inside the workspace; any other block refuses them.
local function read(context)
  local config = config_of(context)
  reject_unknown_keys(config)
  local pinned, pnpm_lock = pinned_of(config)
  local in_workspace = config[pnpm_workspace.KEY] ~= nil
  checked_ranges(pinned.packages, pinned.package_ranges, "dependencies", in_workspace)
  checked_ranges(pinned.dev_packages, pinned.dev_ranges, "devDependencies", in_workspace)
  checked_ranges(pinned.peer_packages, pinned.peer_ranges, "peerDependencies", in_workspace)
  checked_ranges(pinned.optional_packages, pinned.optional_ranges, "optionalDependencies", in_workspace)
  local workspace_root = workspace_root_of(config)
  if workspace_root ~= nil then
    check_member_ranges(config)
    pinned.packages, pinned.package_ranges = member_packages(config, "packages")
    pinned.dev_packages, pinned.dev_ranges = member_packages(config, "devPackages")
    pinned.peer_packages, pinned.peer_ranges = member_packages(config, "peerPackages")
    pinned.optional_packages, pinned.optional_ranges = member_packages(config, "optionalPackages")
    pinned.peer_meta = config.peerPackagesMeta
  end
  local declared_scripts = scripts.read(config)
  local field_names, fields = package_fields.checked(config, config[published.KEY] == nil and WRITTEN or WRITTEN_WHEN_PACKED)
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
    peer_packages = pinned.peer_packages,
    peer_ranges = pinned.peer_ranges,
    optional_packages = pinned.optional_packages,
    optional_ranges = pinned.optional_ranges,
    peer_meta = pinned.peer_meta,
    overrides = pinned.overrides,
    lock = pinned.text ~= nil and pnpm_lock == nil and pinned or nil,
    pnpm_lock = pnpm_lock,
    published = published_of(config),
    nested = nested.read(config),
    workspace = workspace_of(config),
    workspace_root = workspace_root,
  }
end

return {
  read = read,
  package_json = package_json,
  own_name_of = own_name_of,
  package_name_problem = package_name_problem,
  is_project_path = is_project_path,
}
