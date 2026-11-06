daukle.plugin{
  api = 3,
  uses = { "provision", "artifact", "exec", "read", "parse", "write", "json_parse", "list" },
  exports = { "lib/runtimes" },
}

local runtimes = daukle.require("lib/runtimes")
local scripts = daukle.require("lib/scripts")
local runners = daukle.require("lib/runners")
local settings = daukle.require("lib/settings")
local paths = daukle.require("lib/paths")
local tree = daukle.require("lib/tree")
local links = daukle.require("lib/links")
local glob = daukle.require("lib/glob")
local pins = daukle.require("lib/pins")
local npm_launcher = daukle.require("lib/npm_launcher")
local pack = daukle.require("lib/pack")
local published = daukle.require("lib/published")

daukle.toolchain{
  name = "node",
  generate = function(context)
    local spec = settings.read(context)
    runtimes.for_host{ os = context.host.os, arch = context.host.arch, version = spec.version }
    local files = {
      ["package.json"] = settings.package_json(spec),
      [runners.RESOLVER_NAME] = runners.resolver_for(spec.type),
      [runners.BIN_RUNNER_NAME] = runners.BIN_RUNNER,
      [runners.REMOVER_NAME] = runners.REMOVER,
      [tree.SCRIPT_NAME] = tree.SCRIPT,
      [links.SCRIPT_NAME] = links.SCRIPT,
      [npm_launcher.SCRIPT_NAME] = npm_launcher.SCRIPT,
    }
    if spec.lock ~= nil then files["package-lock.json"] = spec.lock.text end
    if spec.published ~= nil then
      files[pack.MANIFEST_NAME] = published.manifest(spec)
      files[pack.SCRIPT_NAME] = pack.SCRIPT
    end
    return files
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

--- npm's own cache, in the derived directory, which the pinned tarballs are added to.
local NPM_CACHE = "npm-cache"

--- Tarballs per `npm cache add`, which keeps one command line far below Windows' 32,767
--- characters at any path length daukle's cache produces.
local CACHE_ADD_BATCH = 50

local function cache_pinned_tarballs(node, npm, lock, host)
  local entries = pins.for_host(lock.entries, host)
  for first = 1, #entries, CACHE_ADD_BATCH do
    local argv = { npm, "cache", "add", "--cache", NPM_CACHE }
    for index = first, math.min(first + CACHE_ADD_BATCH - 1, #entries) do
      local entry = entries[index]
      argv[#argv + 1] = daukle.artifact{ url = entry.url, sha256 = entry.sha256, as = entry.as }
    end
    daukle.exec(node, argv)
  end
end

--- The offline `npm ci` command line for `lock`.
---
--- @implNote a lockfile whose peer conflict npm only warned about makes `npm ci` fetch the
--- conflicting package's packument to warn again, which an offline cache of tarballs never
--- holds (ENOTCACHED, see D-235). Ignoring peer edges skips that fetch and installs the same
--- bytes, but prunes every package placed only as a peer, so it is passed only when there is none.
local function offline_ci(npm, lock)
  local argv = { npm, "ci", "--offline", "--cache", NPM_CACHE, "--no-audit", "--no-fund" }
  if lock.peer_free then argv[#argv + 1] = "--legacy-peer-deps" end
  return argv
end

--- An npm command line that runs lifecycle scripts, run through the launcher so they get this node.
local function through_launcher(npm_argv)
  table.insert(npm_argv, 1, "./" .. npm_launcher.SCRIPT_NAME)
  return npm_argv
end

--- Installs exactly the pinned closure, with npm reaching no network: every tarball this host
--- installs is fetched by daukle against its sha256 and handed to npm's cache, which npm keys
--- by the lockfile's integrity, so a tarball missing from it fails ENOTCACHED naming it.
local function install_packages(context, spec)
  local root, pick = provision_node(context, spec)
  local node, npm = root:tool(pick.node), root:path(pick.npm)
  if spec.lock == nil then
    daukle.exec(node, through_launcher({ npm, "install", "--offline", "--no-audit", "--no-fund" }))
    return root, pick
  end
  cache_pinned_tarballs(node, npm, spec.lock, context.host)
  daukle.exec(node, through_launcher(offline_ci(npm, spec.lock)), { env = spec.lock.env })
  return root, pick
end

local run_steps

--- Runs the project's own `prepare`, which npm runs after a bare install and before a pack (D-243).
local function run_prepare(context, spec)
  for _, script in ipairs(spec.scripts) do
    if script.name == "prepare" then run_steps(context, spec, script) end
  end
end

local function declares_prepare(spec)
  for _, script in ipairs(spec.scripts) do
    if script.name == "prepare" then return true end
  end
  return false
end

local function install_and_link(context, spec)
  local root, pick = install_packages(context, spec)
  daukle.exec(root:tool(pick.node), { "./" .. links.SCRIPT_NAME, context.root })
  return root, pick
end

daukle.task{
  name = "node:install",
  run = function(context)
    local spec = settings.read(context)
    install_and_link(context, spec)
    run_prepare(context, spec)
  end,
}

--[[ @implNote no dependsOn node:install: the migration proof packs while the
     author's package.json is still at the root, where node:install would place
     its own. The stage step exits NO_ROOT_MANIFEST on a root with none, and only
     then is node:install's work done first. ]]
daukle.task{
  name = "node:pack",
  run = function(context)
    local spec = settings.read(context)
    if spec.published == nil then
      error('nothing to pack: "' .. published.KEY .. '" names no package, and npm pack needs its name'
            .. ' and version', 0)
    end
    local root, pick = provision_node(context, spec)
    local node, npm = root:tool(pick.node), root:path(pick.npm)
    if declares_prepare(spec) then
      install_packages(context, spec)
      run_prepare(context, spec)
    end
    local argv = { "./" .. pack.SCRIPT_NAME, "stage", npm, context.root, pack.MANIFEST_NAME, pack.STAGE_DIR, "." }
    local result = daukle.exec(node, argv, { check = false })
    if result.code == pack.NO_ROOT_MANIFEST then
      install_and_link(context, spec)
      result = daukle.exec(node, argv, { check = false })
    end
    if result.code ~= 0 then error("node:pack: node exited with code " .. result.code, 0) end
  end,
}

daukle.task{
  name = "node:migration-proof",
  dependsOn = { "node:tree", "node:pack" },
  run = function() end,
}

--[[ @implNote the migration proof runs before core moves the old package.json
     aside, so tree installs on its own instead of depending on node:install ]]
daukle.task{
  name = "node:tree",
  run = function(context)
    local spec = settings.read(context)
    local root, pick = install_packages(context, spec)
    daukle.exec(root:tool(pick.node), { "./" .. tree.SCRIPT_NAME })
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
local function run_module(context, root, pick, module_path, args, env)
  local derived = derived_from_package_root(context)
  local resolver = (string.sub(derived, 1, 3) == "../" and "" or "./") .. derived .. "/"
                   .. runners.RESOLVER_NAME
  local argv = { "--import", resolver, module_path }
  for index = 1, #args do argv[#argv + 1] = args[index] end
  daukle.exec(root:tool(pick.node), argv, { cwd = package_root(context), env = env })
end

--- A step's arguments with every `{ glob = ... }` expanded against the package root.
local function expanded(context, args)
  local root = package_root(context)
  if root == "." then root = "" end
  local out = {}
  for _, argument in ipairs(args) do
    if type(argument) == "table" then
      for _, path in ipairs(glob.expand(root, argument.glob)) do out[#out + 1] = path end
    else
      out[#out + 1] = argument
    end
  end
  return out
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

local function joined(first, second)
  local out = {}
  for _, item in ipairs(first) do out[#out + 1] = item end
  for _, item in ipairs(second) do out[#out + 1] = item end
  return out
end

--- Runs a script's steps, `appended` going to the end of the last one, which is where npm puts the
--- words after `npm run <name> --`: it appends them to the script's command line (D-244).
function run_steps(context, spec, script, appended)
  for index = 1, #script.steps do
    local step = script.steps[index]
    local extra = index == #script.steps and (appended or {}) or {}
    if step.kind == "script" then
      -- read() has already refused a reference to no script and a cycle, so a
      -- second check here would be a second place for the rule to disagree.
      for other = 1, #spec.scripts do
        if spec.scripts[other].name == step.name then
          run_steps(context, spec, spec.scripts[other], joined(step.args, extra))
        end
      end
    elseif step.kind == "module" then
      local root, pick = provision_node(context, spec)
      run_module(context, root, pick, step.name, expanded(context, joined(step.args, extra)), step.env)
    elseif step.kind == "remove" then
      local root, pick = provision_node(context, spec)
      local argv = { step.recursive and "1" or "0", step.force and "1" or "0" }
      for _, path in ipairs(expanded(context, joined(step.paths, extra))) do argv[#argv + 1] = path end
      run_module(context, root, pick, derived_from_package_root(context) .. "/" .. runners.REMOVER_NAME, argv)
    else
      local root, pick = provision_node(context, spec)
      local argv = { step.name, step.binName or "" }
      for _, argument in ipairs(expanded(context, joined(step.args, extra))) do argv[#argv + 1] = argument end
      run_module(context, root, pick, derived_from_package_root(context) .. "/" .. runners.BIN_RUNNER_NAME, argv,
                 step.env)
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

local migrator = daukle.require("lib/migrator")

daukle.migrator{ tool = "npm", toolchain = "node", run = migrator.run, build = migrator.build }
