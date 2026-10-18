daukle.plugin{
  api = 1,
  uses = { "provision", "exec", "read", "parse" },
  exports = { "lib/runtimes" },
}

local runtimes = daukle.require("lib/runtimes")
local scripts = daukle.require("lib/scripts")
local runners = daukle.require("lib/runners")
local settings = daukle.require("lib/settings")
local paths = daukle.require("lib/paths")

daukle.toolchain{
  name = "node",
  generate = function(context)
    local spec = settings.read(context)
    runtimes.for_host{ os = context.host.os, arch = context.host.arch, version = spec.version }
    return {
      ["package.json"] = settings.package_json(spec),
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
    local spec = settings.read(context)
    local root, pick = provision_node(context, spec)
    daukle.exec(root:tool(pick.node), { root:path(pick.npm), "install" })
  end,
}

local function package_root(context)
  return string.match(context.root, "^%.%./%.%./%.%./(.+)$") or "."
end

local function derived_from_package_root(context)
  return paths.climb_from(package_root(context)) .. "build/daukle/" .. context.toolchain.name
end

--[[ @implNote --import is resolved against the working directory, which is the
     package root here, so the resolver is named relative to it and starts with
     "./" or "../" to stay a relative URL rather than a bare specifier. ]]
local function run_module(context, root, pick, module_path, args)
  local derived = derived_from_package_root(context)
  local resolver = (string.sub(derived, 1, 3) == "../" and "" or "./") .. derived .. "/"
                   .. runners.RESOLVER_NAME
  local argv = { "--import", resolver, module_path }
  for index = 1, #args do argv[#argv + 1] = args[index] end
  daukle.exec(root:tool(pick.node), argv, { cwd = package_root(context) })
end

local function refuse_a_project_with_no_entry(spec)
  if spec.entry ~= nil then return end
  if #spec.scripts == 0 then
    error('this project declares no "entry", so "node:run" has no module to run', 0)
  end
  local names = {}
  for index = 1, #spec.scripts do names[index] = "node:" .. spec.scripts[index].task end
  error('this project declares no "entry", so "node:run" does not name a module: set one, or run'
        .. ' a script directly with ' .. table.concat(names, ", "), 0)
end

daukle.task{
  name = "node:run",
  dependsOn = { "node:install" },
  run = function(context)
    local spec = settings.read(context)
    refuse_a_project_with_no_entry(spec)
    local root, pick = provision_node(context, spec)
    run_module(context, root, pick, spec.entry, {})
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
      run_module(context, root, pick, step.name, step.args)
    else
      local root, pick = provision_node(context, spec)
      local argv = { step.name, step.binName or "" }
      for at = 1, #step.args do argv[#argv + 1] = step.args[at] end
      run_module(context, root, pick, derived_from_package_root(context) .. "/" .. runners.BIN_RUNNER_NAME, argv)
    end
  end
end

-- The NAME is closed over and the script is looked up at task time, because the
-- chunk saw the primary manifest alone and a daukle.lua overlay may have
-- changed what the script does by the time it runs.
local function run_script(script_name)
  return function(context)
    local spec = settings.read(context)
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
