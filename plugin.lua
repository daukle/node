daukle.plugin{
  api = 1,
  uses = { "provision", "exec", "read", "parse" },
  exports = { "lib/runtimes" },
}

local runtimes = daukle.require("lib/runtimes")
local scripts = daukle.require("lib/scripts")
local runners = daukle.require("lib/runners")

local KNOWN_KEYS = { version = true, entry = true, packages = true, devPackages = true,
                     scripts = true }

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

--[[ @implNote "entry" is required only when nothing else says what to run. A
     project that declares scripts has named several things to run and has no
     reason to elect one, so demanding an entry there would be demanding a
     module it does not have; node:run names the scripts instead. ]]
local function entry_of(config, declared_scripts)
  local entry = config.entry
  if entry == nil then
    if #declared_scripts > 0 then return nil end
    error('a node toolchain needs an "entry": the module "node:run" runs cannot be inferred', 0)
  end
  if type(entry) ~= "string" then
    error('"entry" must name a module as a path string, not a ' .. type(entry), 0)
  end
  if entry == "" or climbs_out(entry) then
    error(string.format('"entry" must name a module inside the project, and "%s" does not', entry), 0)
  end
  return entry
end

local SCOPED = "^@[%w][%w%.%_%-]*/[%w][%w%.%_%-]*$"
local PLAIN = "^[%w][%w%.%_%-]*$"

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
    if type(name) ~= "string"
       or (string.match(name, PLAIN) == nil and string.match(name, SCOPED) == nil) then
      error(string.format('"%s" is not an npm package name: a name is "lodash" or "@scope/name"',
                          tostring(name)), 0)
    end
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
  return '{\n'
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
    entry = entry_of(config, declared_scripts),
    scripts = declared_scripts,
    packages = packages,
    package_ranges = package_ranges,
    dev_packages = dev_packages,
    dev_ranges = dev_ranges,
  }
end

daukle.toolchain{
  name = "node",
  generate = function(context)
    local spec = read(context)
    runtimes.for_host{ os = context.host.os, arch = context.host.arch, version = spec.version }
    return {
      ["package.json"] = package_json(spec),
      [runners.RESOLVER_NAME] = runners.RESOLVER,
      [runners.BIN_RUNNER_NAME] = runners.BIN_RUNNER,
    }
  end,
}

local function provision_node(context, spec)
  local pick = runtimes.for_host{ os = context.host.os, arch = context.host.arch,
                                  version = spec.version }
  local root = daukle.provision{
    url = pick.url,
    sha256 = pick.sha256,
    as = "node " .. pick.version,
  }
  return root, pick
end

--[[ @implNote "npm ci" is not reachable: it is wanted only when a lockfile is
     present and a plugin cannot ask whether a file exists, since daukle.read
     raises on a missing one and pcall is not in the sandbox. It is also not
     wanted. ci refuses when the lockfile disagrees with package.json, and
     daukle GENERATES package.json, so the only way they can disagree is that
     the manifest changed, which is exactly when reconciling is right and
     refusing is wrong. ]]
daukle.task{
  name = "node:install",
  run = function(context)
    local spec = read(context)
    local root, pick = provision_node(context, spec)
    daukle.exec(root:tool(pick.node), { root:path(pick.npm), "install" })
  end,
}

-- Relative, and correct because a task's working directory is the derived
-- directory the resolver was generated into. The resolver itself is what hands
-- descendants the absolute form, since context.root is "../../.." and a plugin
-- has no absolute path to the project at all.
local function run_module(root, pick, module_path, args)
  local argv = { "--import", "./" .. runners.RESOLVER_NAME, module_path }
  for index = 1, #args do argv[#argv + 1] = args[index] end
  daukle.exec(root:tool(pick.node), argv)
end

local function refuse_a_project_with_no_entry(spec)
  if spec.entry ~= nil then return end
  local names = {}
  for index = 1, #spec.scripts do names[index] = "node:" .. spec.scripts[index].task end
  error('this project declares no "entry", so "node:run" does not name a module: set one, or run'
        .. ' a script directly with ' .. table.concat(names, ", "), 0)
end

daukle.task{
  name = "node:run",
  dependsOn = { "node:install" },
  run = function(context)
    local spec = read(context)
    refuse_a_project_with_no_entry(spec)
    local root, pick = provision_node(context, spec)
    run_module(root, pick, context.root .. "/" .. spec.entry, {})
  end,
}

local function run_steps(context, spec, script)
  for index = 1, #script.steps do
    local step = script.steps[index]
    if step.kind == "script" then
      -- read() has already refused a reference to no script and a cycle, so a
      -- second check here would be a second place for the rule to disagree.
      for other = 1, #spec.scripts do
        if spec.scripts[other].name == step.name then
          run_steps(context, spec, spec.scripts[other])
        end
      end
    elseif step.kind == "module" then
      local root, pick = provision_node(context, spec)
      run_module(root, pick, context.root .. "/" .. step.name, step.args)
    else
      local root, pick = provision_node(context, spec)
      local argv = { step.name, step.binName or "" }
      for at = 1, #step.args do argv[#argv + 1] = step.args[at] end
      run_module(root, pick, "./" .. runners.BIN_RUNNER_NAME, argv)
    end
  end
end

-- The NAME is closed over and the script is looked up at task time, because the
-- chunk saw the primary manifest alone and a daukle.lua overlay may have
-- changed what the script does by the time it runs.
local function run_script(script_name)
  return function(context)
    local spec = read(context)
    for index = 1, #spec.scripts do
      if spec.scripts[index].name == script_name then
        run_steps(context, spec, spec.scripts[index])
        return
      end
    end
    error(string.format('"%s" is no longer a declared script', script_name), 0)
  end
end

--[[ One task per script, which is what makes a package's SECOND entry point
     reachable: node:run takes one module and a package.json carries a map.
     Gated on the manifest being declarative, because core accepts a project
     whose ONLY manifest is daukle.lua by falling back to the overlay, and
     daukle.parse refuses to run one. There is no pcall here, so an unguarded
     parse is fatal on every command rather than only on these tasks: that is
     what daukle/cmake@1.4.0 shipped. Such a project keeps node:install and
     node:run, because nothing a chunk can reach sees a Lua-declared config. ]]
local function declarative_manifest()
  if string.match(daukle.manifest, "%.toml$") == nil then return nil end
  return daukle.parse(daukle.read(daukle.manifest), daukle.manifest)
end

local document = declarative_manifest()
for _, script in ipairs(document ~= nil and scripts.task_scripts(document) or {}) do
  -- The npm script keeps its own spelling, which is what package.json and a
  -- reader's muscle memory both carry; only the task name is mapped.
  daukle.task{
    name = "node:" .. script.task,
    dependsOn = { "node:install" },
    run = run_script(script.name),
  }
end
