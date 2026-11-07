local engines = daukle.require("lib/engines")
local command_line = daukle.require("lib/command_line")
local scripts = daukle.require("lib/scripts")
local settings = daukle.require("lib/settings")
local package_fields = daukle.require("lib/package_fields")
local published = daukle.require("lib/published")

local SURFACE = {
  dependencies = "3. Dependencies",
  overrides = "3. Dependencies: `overrides`",
  scripts = "5. Scripts",
  shell = package_fields.ROWS.shell,
  prepost = "5. Scripts: `pre<name>` and `post<name>` run automatically",
  lifecycle = "5. Scripts: the project's own lifecycle scripts on install: `preinstall`, `prepare`",
  publishing = "7. Packing and publishing",
  engines = "1. The runtime",
  engines_field = "1. The runtime: `engines.node` / `engines.npm` in the package",
  module = "1. The runtime: `node <module>`",
  type = "2. Module resolution: the project's own `\"type\"`",
  tarball = "3. Dependencies: a tarball URL holding `?`, `%` or `&`",
  local_path = "3. Dependencies: local paths, `file:`",
  workspaces = package_fields.ROWS.workspaces,
  non_registry = "3. Dependencies: dist-tags, git URLs, `user/repo`, `npm:` aliases",
}

local GIT_PREFIXES = { "git+", "git:", "github:", "gitlab:", "bitbucket:", "gist:" }

--- What a specifier resolves to outside the registry, or nil for a registry range or dist-tag:
--- daukle/npm and daukle/pnpm pin only a registry tarball, and raise on anything else.
local function non_registry_kind(range)
  local lowered = string.lower(range)
  if string.sub(lowered, 1, 4) == "npm:" then return "an npm alias" end
  for _, prefix in ipairs(GIT_PREFIXES) do
    if string.sub(lowered, 1, #prefix) == prefix then return "a git repository" end
  end
  if string.find(lowered, "://", 1, true) then return "a url" end
  if string.match(range, "^[%w][%w%-%._]*/[%w%-%._]+") then return "a GitHub \"user/repo\" shorthand" end
  return nil
end

local WORKSPACE_PROTOCOLS = {
  { prefix = "workspace:", what = "the workspace protocol, which links a sibling package of a workspace" },
  { prefix = "catalog:", what = "a pnpm catalog reference, which takes its range from the workspace's catalog" },
}

local function workspace_protocol_of(range)
  for _, protocol in ipairs(WORKSPACE_PROTOCOLS) do
    if string.sub(string.lower(range), 1, #protocol.prefix) == protocol.prefix then return protocol end
  end
  return nil
end

local ABSENT_FIELDS = package_fields.ABSENT
local METADATA = package_fields.METADATA
local READ = package_fields.READ

local LIFECYCLE = {}
for _, name in ipairs({ "preinstall", "install", "postinstall", "preprepare",
                        "postprepare", "prepublish", "prepublishOnly", "publish", "postpublish",
                        "prepack", "pack", "postpack", "preversion", "version", "postversion",
                        "dependencies" }) do
  LIFECYCLE[name] = true
end

local BOM = "\239\187\191"

local function blocker(blockers, construct, where, why, surface)
  blockers[#blockers + 1] = { construct = construct, where = where, why = why,
                              surface = surface and ("NPM-SURFACE.md: " .. surface) or nil }
end

local function sorted_keys(map)
  local keys = {}
  for key in pairs(map) do keys[#keys + 1] = key end
  table.sort(keys)
  return keys
end

--[[ @implNote the forms are npm-package-arg's: a protocol of file: or link:,
     a leading ".", "/", "~/" or drive letter, or a tarball file name. npm
     resolves each against the generated package.json's directory, not the
     author's. ]]
local function is_local_path(range)
  local lowered = string.lower(range)
  if string.match(lowered, "^file:") or string.match(lowered, "^link:") then return true end
  if string.match(range, "^[%./]") or string.match(range, "^~/") or string.match(range, "^%a:") then
    return true
  end
  return string.find(lowered, "://", 1, true) == nil
         and (string.match(lowered, "%.tgz$") or string.match(lowered, "%.tar%.gz$")
              or string.match(lowered, "%.tar$")) ~= nil
end

--- Whether a workspace member keeps `range` as written, for pnpm to resolve inside the workspace:
--- a `workspace:` or `catalog:` range, or a `file:` range naming a directory the member accepts.
local function is_kept_by_member(member, range)
  if member == nil or type(range) ~= "string" then return false end
  if workspace_protocol_of(range) ~= nil then return true end
  return string.sub(string.lower(range), 1, 5) == "file:" and member.keeps_file_range(range)
end

local function dependency_map(package, key, where, blockers, member)
  local map = package[key]
  if map == nil then return nil end
  if type(map) ~= "table" or #map > 0 then
    blocker(blockers, '"' .. key .. '"', where, "is not a map of package name to range",
            SURFACE.dependencies)
    return nil
  end
  local out, any = {}, false
  for _, name in ipairs(sorted_keys(map)) do
    local range = map[name]
    local name_problem = settings.package_name_problem(name)
    local protocol = type(range) == "string" and workspace_protocol_of(range) or nil
    if name_problem ~= nil then
      blocker(blockers, key .. '."' .. name .. '"', where, name_problem, SURFACE.dependencies)
    elseif is_kept_by_member(member, range) then
      out[name] = range
      any = true
    elseif type(range) == "string" and is_local_path(range) then
      blocker(blockers, key .. '."' .. name .. '"', where, string.format('is "%s", a local path'
              .. ' npm would resolve against the generated package.json\'s directory rather than'
              .. ' this one', range), SURFACE.local_path)
    elseif protocol ~= nil then
      blocker(blockers, key .. '."' .. name .. '"', where, string.format('is "%s", %s, and this'
              .. ' toolchain has no workspaces', range, protocol.what),
              SURFACE.workspaces)
    elseif type(range) ~= "string"
           or not string.match(range, '^[%w%s%.%-%+%*|<>=~^%(%)/:#@]+$') then
      blocker(blockers, key .. '."' .. name .. '"', where,
              "is a specifier this toolchain cannot write into its generated package.json",
              SURFACE.tarball)
    elseif non_registry_kind(range) ~= nil then
      blocker(blockers, key .. '."' .. name .. '"', where, string.format('is "%s", %s, which'
              .. ' resolves outside the registry, and only a registry tarball can be pinned',
              range, non_registry_kind(range)), SURFACE.non_registry)
    else
      out[name] = range
      any = true
    end
  end
  return any and out or nil
end

local function is_paired(name, declared)
  local base = string.match(name, "^pre(.+)$") or string.match(name, "^post(.+)$")
  return base ~= nil and declared[base] ~= nil
end

local function translated_script(name, body, declared, where, blockers, workspace_members)
  local construct = 'scripts."' .. name .. '"'
  if LIFECYCLE[name] then
    blocker(blockers, construct, where, "is an npm lifecycle script, run on an event daukle has"
            .. " no equivalent for", SURFACE.lifecycle)
    return nil
  end
  if is_paired(name, declared) then
    blocker(blockers, construct, where, "runs automatically around another script in npm, and"
            .. " as its own task it would change what that script does", SURFACE.prepost)
    return nil
  end
  local problem = scripts.task_name_problem(name)
  if problem ~= nil then
    blocker(blockers, construct, where, problem, SURFACE.scripts)
    return nil
  end
  if type(body) ~= "string" then
    blocker(blockers, construct, where, "is not a command line", SURFACE.scripts)
    return nil
  end
  local parsed, reason = command_line.parse(body)
  if parsed == nil then
    blocker(blockers, construct, where, reason, SURFACE.shell)
    return nil
  end
  local steps = {}
  for index, words in ipairs(parsed.segments) do
    local step, why = command_line.step_of(words, declared, workspace_members)
    if step == nil then
      blocker(blockers, construct, where, why, SURFACE.shell)
      return nil
    end
    if parsed.operators[index - 1] == "||" then
      steps = { { attempt = steps, otherwise = { step } } }
    else
      steps[#steps + 1] = step
    end
  end
  if #steps == 1 then return steps[1] end
  return steps
end

local function translated_scripts(package, where, blockers, workspace_members)
  local map = package.scripts
  if map == nil then return nil end
  if type(map) ~= "table" or #map > 0 then
    blocker(blockers, '"scripts"', where, "is not a map of script name to command", SURFACE.scripts)
    return nil
  end
  local out, any, tasks = {}, false, {}
  for _, name in ipairs(sorted_keys(map)) do
    local task = scripts.task_name_of(name)
    if tasks[task] ~= nil then
      blocker(blockers, 'scripts."' .. name .. '"', where, string.format('"%s" and "%s" would be'
              .. ' the same daukle task "node:%s"', tasks[task], name, task), SURFACE.scripts)
    else
      tasks[task] = name
      local step = translated_script(name, map[name], map, where, blockers, workspace_members)
      if step ~= nil then out[name] = step any = true end
    end
  end
  return any and out or nil
end

local function entry_of(package, has_scripts, where, blockers)
  local main = package.main
  if main == nil then return nil end
  if type(main) ~= "string" then
    blocker(blockers, '"main"', where, "is not a path", SURFACE.publishing)
    return nil
  end
  if has_scripts then return nil end
  local entry = string.gsub(main, "^%./", "")
  if not settings.is_project_path(entry) then
    blocker(blockers, '"main"', where, string.format('names "%s", which is not a module inside'
            .. ' the project', main), SURFACE.module)
    return nil
  end
  return entry
end

--- The `engines.node` and `engines.npm` ranges; `engines` itself is carried verbatim.
local function engine_ranges(package, where, blockers)
  local map = package.engines
  if map == nil then return nil, nil end
  if type(map) ~= "table" or #map > 0 then
    blocker(blockers, '"engines"', where, "is not a map of engine name to range",
            SURFACE.engines_field)
    return nil, nil
  end
  return map.node, map.npm
end

--- Every step of a script, an `attempt` step's own steps included, in order.
local function steps_in(step_or_steps)
  local listed = step_or_steps[1] ~= nil and step_or_steps or { step_or_steps }
  local out = {}
  for _, step in ipairs(listed) do
    if step.attempt ~= nil then
      for _, inner in ipairs(steps_in(step.attempt)) do out[#out + 1] = inner end
      for _, inner in ipairs(steps_in(step.otherwise)) do out[#out + 1] = inner end
    else
      out[#out + 1] = step
    end
  end
  return out
end

--- Every top-level member's name, sorted.
---
--- @implNote the raw names as well as the parsed ones, because a member whose
--- value is JSON `null` has no key in the parsed table and would be dropped.
local function member_names(parsed, raw)
  local seen, names = {}, {}
  for _, source in ipairs({ parsed, raw }) do
    for name in pairs(source) do
      if not seen[name] then
        seen[name] = true
        names[#names + 1] = name
      end
    end
  end
  table.sort(names)
  return names
end

--- An unknown field into `packageFields` verbatim, or a blocker when its text cannot be told.
local function carry_field(config, key, raw, where, blockers)
  if raw == nil then
    blocker(blockers, '"' .. key .. '"', where, "is a field this migrator does not know, named with an"
            .. " escape it cannot carry verbatim, and a field it does not know is never dropped", nil)
    return
  end
  config[package_fields.KEY] = config[package_fields.KEY] or {}
  config[package_fields.KEY][key] = raw
end

--- Whether `node:pack` publishes this package: where it declares what a tarball holds, what it
--- `exports` or how it is published, or offers consumers a `main` that is not its own run entry,
--- which only packing gives a meaning (D-238).
local function is_packed(parsed, has_scripts)
  return parsed.files ~= nil or parsed.exports ~= nil or parsed.publishConfig ~= nil
         or (parsed.main ~= nil and parsed.private ~= true and has_scripts)
end

--- The consumer-facing fields as their raw JSON text, for `node:pack`'s manifest.
local function published_fields(parsed, raw, where, blockers)
  local out = {}
  for _, key in ipairs(member_names(parsed, raw)) do
    if published.FIELDS[key] then
      if raw[key] == nil then
        blocker(blockers, '"' .. key .. '"', where, "is named with an escape this migrator cannot"
                .. " carry verbatim into the packed manifest", SURFACE.publishing)
      else
        out[key] = raw[key]
      end
    end
  end
  for _, required in ipairs({ "name", "version" }) do
    if type(parsed[required]) ~= "string" then
      blocker(blockers, '"' .. required .. '"', where, "is missing or not a string, and npm pack names"
              .. " the tarball of a package that declares \"files\", \"exports\" or \"publishConfig\""
              .. " or offers a \"main\" by it",
              SURFACE.publishing)
    end
  end
  return out
end

--- The `overrides` object as its raw JSON text, which daukle/npm resolves with verbatim.
local function overrides_of(parsed, raw, where, blockers)
  if parsed.overrides == nil then return nil end
  if type(parsed.overrides) ~= "table" or string.match(raw.overrides or "", "^{") == nil then
    blocker(blockers, '"overrides"', where, "is not an object, and npm reads only an object of"
            .. " package name to override", SURFACE.overrides)
    return nil
  end
  return raw.overrides
end

--- The pnpm release a `"packageManager": "pnpm@<version>"` names, or nil for any other value.
---
--- @implNote a corepack `+sha512.<hex>` suffix is dropped: daukle/pnpm pins the release by its own
--- sha256 and refuses one it does not pin.
local function pnpm_release_of(package_manager)
  if type(package_manager) ~= "string" then return nil end
  return string.match(package_manager, "^pnpm@(%d+%.%d+%.%d+)$")
         or string.match(package_manager, "^pnpm@(%d+%.%d+%.%d+)%+sha%d+%.[%x]+$")
end

--- @param member table|nil for a pnpm workspace member's own run, `{ keeps_file_range }`, which
--- says whether a `file:` range names a directory inside its workspace.
--- @param workspace_members table|nil for a workspace root's run, each member's package name mapped
--- to its directory, which `pnpm --filter <name>` addresses.
local function package(text, where, member, workspace_members)
  local blockers = {}
  if type(text) == "string" and string.sub(text, 1, 3) == BOM then text = string.sub(text, 4) end
  local ok_text = type(text) == "string" and string.match(text, "^%s*{") ~= nil
  if not ok_text then
    blocker(blockers, "package.json", where, "is not a JSON object", nil)
    return { config = {}, blockers = blockers, commands = {} }
  end
  local parsed = daukle.json_parse(text)
  local config = {}
  local raw = package_fields.raw_members(text)
  local pnpm = pnpm_release_of(parsed.packageManager)
  for _, key in ipairs(member_names(parsed, raw)) do
    if key == "packageManager" and pnpm ~= nil then
      config.pnpm = pnpm
    elseif ABSENT_FIELDS[key] ~= nil then
      blocker(blockers, '"' .. key .. '"', where, "has no equivalent in this toolchain",
              ABSENT_FIELDS[key])
    elseif not READ[key] and not METADATA[key] then
      carry_field(config, key, raw[key], where, blockers)
    end
  end
  local candidates, why, engine = engines.satisfying(engine_ranges(parsed, where, blockers))
  if candidates == nil then blocker(blockers, "engines." .. engine, where, why, SURFACE.engines) end
  config.version = candidates and candidates[1]
  config.overrides = overrides_of(parsed, raw, where, blockers)
  config.packages = dependency_map(parsed, "dependencies", where, blockers, member)
  config.devPackages = dependency_map(parsed, "devDependencies", where, blockers, member)
  if parsed.type ~= nil then
    if parsed.type == "module" or parsed.type == "commonjs" then
      config.type = parsed.type
    else
      blocker(blockers, '"type"', where, "is neither \"module\" nor \"commonjs\"", SURFACE.type)
    end
  end
  config.scripts = translated_scripts(parsed, where, blockers, workspace_members)
  config.entry = entry_of(parsed, config.scripts ~= nil, where, blockers)
  if is_packed(parsed, config.scripts ~= nil) then config[published.KEY] = published_fields(parsed, raw, where, blockers) end
  local commands = {}
  for _, step_or_steps in pairs(config.scripts or {}) do
    for _, step in ipairs(steps_in(step_or_steps)) do
      if step.command ~= nil then commands[step.command] = true end
    end
  end
  return { config = config, blockers = blockers, commands = commands, original_scripts = parsed.scripts,
           candidates = candidates or {} }
end

--[[ @implNote the bin runner looks "binName or the package name" up in a map
     bin, and refuses any other binName on a string bin, so whether binName is
     written depends on the provider's bin SHAPE, not on its name. ]]
local function bin_name_for(command, provider)
  if provider.map and command ~= provider.name then return command end
  return nil
end

local function provider_names(providers)
  local names = {}
  for index, provider in ipairs(providers) do names[index] = provider.name end
  return table.concat(names, " and ")
end

local function resolve_commands(config, bins, where)
  local blockers = {}
  for _, name in ipairs(sorted_keys(config.scripts or {})) do
    for _, step in ipairs(steps_in(config.scripts[name])) do
      if step.command ~= nil then
        local providers = bins[step.command] or {}
        if #providers == 0 then
          blocker(blockers, 'scripts."' .. name .. '"', where, string.format('runs "%s", which no'
                  .. ' installed package provides', step.command), SURFACE.scripts)
        elseif #providers > 1 then
          blocker(blockers, 'scripts."' .. name .. '"', where, string.format('runs "%s", which'
                  .. ' both %s provide', step.command, provider_names(providers)),
                  SURFACE.scripts)
        else
          step.bin = providers[1].name
          step.binName = bin_name_for(step.command, providers[1])
          step.command = nil
        end
      end
    end
  end
  return blockers
end

return { package = package, resolve_commands = resolve_commands, SURFACE = SURFACE }
