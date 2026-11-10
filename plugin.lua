daukle.plugin{
  api = 10,
  uses = { "provision", "artifact", "exec", "read", "parse", "write", "json_parse", "list", "run_task" },
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
local workspace_ranges = daukle.require("lib/workspace_ranges")
local pnpm_mirror = daukle.require("lib/pnpm_mirror")
local nested = daukle.require("lib/nested")
local pnpm_workspace = daukle.require("lib/pnpm_workspace")
local instance_name = daukle.require("lib/instance_name")

daukle.toolchain{
  name = "node",
  generate = function(context)
    local spec = settings.read(context)
    runtimes.for_host{ os = context.host.os, arch = context.host.arch, version = spec.version }
    local files = {
      ["package.json"] = settings.package_json(spec),
      [runners.RESOLVER_NAME] = runners.resolver_for(spec.type, settings.own_name_of(spec),
                                                     spec.workspace ~= nil or spec.workspace_root ~= nil),
      [runners.BIN_RUNNER_NAME] = runners.BIN_RUNNER,
      [runners.REMOVER_NAME] = runners.REMOVER,
      [runners.ECHO_NAME] = runners.ECHO,
      [tree.SCRIPT_NAME] = tree.SCRIPT,
      [links.SCRIPT_NAME] = links.SCRIPT,
      [npm_launcher.SCRIPT_NAME] = npm_launcher.SCRIPT,
      [nested.PLACEMENTS_NAME] = nested.placements_json(spec.nested),
      [links.WORKSPACE_NAME] = links.workspace_json(spec),
    }
    if spec.workspace ~= nil then files[links.WORKSPACE_FILE_NAME] = pnpm_workspace.render(spec.workspace) end
    if spec.lock ~= nil then files["package-lock.json"] = spec.lock.text end
    if spec.pnpm_lock ~= nil then
      files["pnpm-lock.yaml"] = spec.pnpm_lock.text
      files[pnpm_mirror.SCRIPT_NAME] = pnpm_mirror.SCRIPT
    end
    if spec.published ~= nil then files[pack.MANIFEST_NAME] = published.manifest(spec) end
    if spec.published ~= nil or spec.workspace ~= nil then files[pack.SCRIPT_NAME] = pack.SCRIPT end
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

--- The path of what runs the pinned pnpm: its entry script, or from 12 this host's native binary.
local function provisioned_pnpm(context, pnpm)
  local as = "pnpm " .. pnpm.version
  if pnpm.binaries == nil then
    return daukle.provision{ url = pnpm.url, sha256 = pnpm.sha256, as = as }:path("package/bin/pnpm.cjs")
  end
  local binary = pnpm.binaries[context.host.os .. "/" .. context.host.arch]
  if binary == nil then
    error(string.format("pnpm %s has no pinned binary for this host (%s %s)", pnpm.version, context.host.os,
                        context.host.arch), 0)
  end
  return daukle.provision{ url = binary.url, sha256 = binary.sha256, as = as }:path(binary.file)
end

--- The pinned pnpm, with the mirror's map of the tarballs daukle fetched written beside it.
local function pnpm_behind_mirror(context, lock)
  local fetched = {}
  for _, entry in ipairs(pins.for_host(lock.entries, context.host)) do
    fetched[#fetched + 1] = { url = entry.url, file = daukle.artifact{ url = entry.url, sha256 = entry.sha256, as = entry.as } }
  end
  daukle.write{ path = pnpm_mirror.MAP_NAME, text = pnpm_mirror.map_json(fetched) }
  return provisioned_pnpm(context, lock.pnpm)
end

--- Installs a pnpm project's pinned closure with its pinned pnpm, through a loopback mirror of
--- the tarballs daukle fetched, so `--frozen-lockfile` reaches no network (D-251).
local function install_with_pnpm(context, spec, root, pick)
  local pnpm = pnpm_behind_mirror(context, spec.pnpm_lock)
  daukle.exec(root:tool(pick.node), { "./" .. pnpm_mirror.SCRIPT_NAME, pnpm_mirror.MAP_NAME, pnpm, "install",
                                      "--frozen-lockfile", "--store-dir", "pnpm-store" })
  return root, pick
end

--- Installs exactly the pinned closure, with npm reaching no network: every tarball this host
--- installs is fetched by daukle against its sha256 and handed to npm's cache, which npm keys
--- by the lockfile's integrity, so a tarball missing from it fails ENOTCACHED naming it.
---
--- @implNote a workspace member installs nothing of its own, whatever task asks: the one install
--- of the workspace is its root's `node:install`, which a member's runs.
local function install_packages(context, spec)
  local root, pick = provision_node(context, spec)
  if spec.workspace_root ~= nil then return root, pick end
  if spec.pnpm_lock ~= nil then return install_with_pnpm(context, spec, root, pick) end
  local node, npm = root:tool(pick.node), root:path(pick.npm)
  if spec.lock == nil then
    daukle.exec(node, through_launcher({ npm, "install", "--offline", "--no-audit", "--no-fund" }))
    return root, pick
  end
  cache_pinned_tarballs(node, npm, spec.lock, context.host)
  daukle.exec(node, through_launcher(offline_ci(npm, spec.lock)), { env = spec.lock.env })
  return root, pick
end

local run_steps, run_script_steps

local function run_declared_script(context, spec, name)
  for _, script in ipairs(spec.scripts) do
    if script.name == name then run_script_steps(context, spec, script) end
  end
end

--- Runs the project's own `prepare`, which npm runs after a bare install and before a pack (D-243).
local function run_prepare(context, spec)
  run_declared_script(context, spec, "prepare")
end

local function declares_a_pack_script(spec)
  for _, script in ipairs(spec.scripts) do
    if script.name == "prepare" or script.name == "prepack" or script.name == "postpack" then return true end
  end
  return false
end

local function package_root(context)
  return string.match(context.root, "^%.%./%.%./%.%./(.+)$") or "."
end

local function derived_from_package_root(context)
  return paths.climb_from(package_root(context)) .. "build/daukle/" .. context.toolchain.name
end

--- The directory of the bin runner for `step`: its own instance's, or for a command only the
--- workspace root provides the root's, whose runner reads the root's modules.
local function bin_runner_directory(context, spec, step)
  if not step.from_workspace_root then return derived_from_package_root(context) .. "/" end
  if spec.workspace_root == nil then
    error(string.format('a step of this block runs "%s" with "fromWorkspaceRoot", and this block is no'
                        .. ' workspace member, so it has no workspace root', step.name), 0)
  end
  return paths.climb_from(package_root(context)) .. "build/daukle/" .. spec.workspace_root .. "/"
end

--- Places this instance's generated files at its package root and links its node_modules there.
local function place_at_package_root(context, root, pick)
  daukle.exec(root:tool(pick.node), { "./" .. links.SCRIPT_NAME, context.root })
end

local function run_task_of(name)
  local ok, why = daukle.run_task(name)
  if not ok then error(name .. " failed: " .. tostring(why), 0) end
end

local function place_member(member)
  local ok, why = daukle.run_task(member.instance .. ":place")
  if ok then return end
  error(string.format('workspace.members."%s" names the instance "%s", and its place task failed: %s',
                      member.dir, member.instance, tostring(why)), 0)
end

--- This member's directory below its workspace root, as the root's `workspace.members` maps it;
--- a member the root does not list is refused, since pnpm installed nothing for it.
local function member_dir_in_root(context, spec)
  local placements = daukle.json_parse(daukle.read("build/daukle/" .. spec.workspace_root .. "/" .. links.WORKSPACE_NAME))
  local dir = (placements.members or {})[context.toolchain.name]
  if type(dir) == "string" then return dir end
  error(string.format('this block names "%s" as its workspace root, and that root\'s workspace.members does'
                      .. ' not list "%s", so the workspace install placed nothing for it', spec.workspace_root,
                      context.toolchain.name), 0)
end

local function refuse_an_unlisted_member(context, spec)
  member_dir_in_root(context, spec)
end

local function refuse_a_workspace_without_pins(spec)
  if spec.pnpm_lock ~= nil then return end
  error("a pnpm workspace installs the closure daukle/pnpm pins, and this block carries no pins: resolve"
        .. " them with daukle/pnpm first", 0)
end

--- The one install of a pnpm workspace, run from its root's own directory once every project's
--- `package.json`, the workspace file and the lockfile are placed there, with everything pnpm
--- writes kept under `build/`: each project's modules in its own `build/daukle/node_modules`, the
--- virtual store and the store in the root's derived directory. Every member is placed and linked
--- by it, so a member's own modules resolve when only a sibling's task ran this install.
---
--- @implNote a member is linked before the install, not after it: its `:place` runs at most once
--- per invocation, and the link names a directory pnpm then fills.
---
--- @implNote the root is linked before the install as well as after it: pnpm 10 and 11 write
--- `node_modules/.pnpm-workspace-state-v1.json` at the workspace root whatever `--modules-dir`
--- says, and exit 254 when that `node_modules` is a link whose target is gone, as after
--- `daukle clean`; linked first, the file lands under `build/`.
---
--- @implNote `confirmModulesPurge=false` because pnpm 10.34.9 and 11.25.0, finding a modules
--- directory laid out for another virtual store or release, ask before purging it and without a
--- TTY exit 1 with ERR_PNPM_ABORTED_REMOVE_MODULES_DIR_NO_TTY instead (measured in Docker by moving
--- `--virtual-store-dir` between two installs; 8.9.2 prompts and proceeds).
local function install_workspace(context, spec, root, pick)
  refuse_a_workspace_without_pins(spec)
  for _, member in ipairs(spec.workspace.members) do place_member(member) end
  place_at_package_root(context, root, pick)
  local derived = derived_from_package_root(context)
  local pnpm = pnpm_behind_mirror(context, spec.pnpm_lock)
  daukle.exec(root:tool(pick.node), {
    derived .. "/" .. pnpm_mirror.SCRIPT_NAME, derived .. "/" .. pnpm_mirror.MAP_NAME, pnpm, "install",
    "--frozen-lockfile", "--config.confirmModulesPurge=false", "--modules-dir", links.WORKSPACE_MODULES_DIR,
    "--virtual-store-dir", derived .. "/pnpm-virtual-store", "--store-dir", derived .. "/pnpm-store",
  }, { cwd = package_root(context) })
  place_at_package_root(context, root, pick)
end

local function install_and_link(context, spec)
  if spec.workspace ~= nil then
    local root, pick = provision_node(context, spec)
    install_workspace(context, spec, root, pick)
    return root, pick
  end
  if spec.workspace_root ~= nil then
    run_task_of(spec.workspace_root .. ":install")
    refuse_an_unlisted_member(context, spec)
  end
  local root, pick = install_packages(context, spec)
  place_at_package_root(context, root, pick)
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

daukle.task{
  name = "node:place",
  run = function(context)
    local root, pick = provision_node(context, settings.read(context))
    place_at_package_root(context, root, pick)
  end,
}

--- The name of the manifest `node:pack` publishes, written with its workspace ranges resolved in a
--- task because a sibling's version is another instance's generated file.
local function publishable_manifest(context, spec)
  if not workspace_ranges.applies(spec) then return pack.MANIFEST_NAME end
  daukle.write{ path = pack.RESOLVED_MANIFEST_NAME,
                text = published.manifest(workspace_ranges.resolved(spec, context.toolchain.name)) }
  return pack.RESOLVED_MANIFEST_NAME
end

--- The workspace's rendered root and member package.json files, its rendered workspace file and
--- the pinned lockfile, written into `directory` below this toolchain's derived directory.
local function write_rendered_workspace(spec, directory)
  refuse_a_workspace_without_pins(spec)
  daukle.write{ path = directory .. "/package.json", text = settings.package_json(spec) }
  daukle.write{ path = directory .. "/" .. pnpm_workspace.NAME, text = pnpm_workspace.render(spec.workspace) }
  daukle.write{ path = directory .. "/pnpm-lock.yaml", text = spec.pnpm_lock.text }
  for _, member in ipairs(spec.workspace.members) do
    daukle.write{ path = directory .. "/" .. member.dir .. "/package.json",
                  text = daukle.read("build/daukle/" .. member.instance .. "/package.json") }
  end
end

--- The derived directory a workspace package's `prepare` takes its modules from.
local SOURCE_WORKSPACE = "source-workspace"

--- The workspace rebuilt with its sources and installed, for a `prepare` to read its dependencies
--- and its siblings' files.
---
--- @implNote a separate rebuild rather than `node:install`: the migration proof runs this while the
--- author's package.json files are at their paths, where placing the generated ones is refused. A
--- rendered manifest declares no scripts, so only a dependency's own build runs here.
daukle.task{
  name = "node:source-workspace",
  run = function(context)
    local spec = settings.read(context)
    local root, pick = provision_node(context, spec)
    daukle.exec(root:tool(pick.node), { "./" .. pack.SCRIPT_NAME, "copy-sources", root:path(pick.npm), context.root, SOURCE_WORKSPACE })
    write_rendered_workspace(spec, SOURCE_WORKSPACE)
    local pnpm = pnpm_behind_mirror(context, spec.pnpm_lock)
    daukle.exec(root:tool(pick.node), {
      "../" .. pnpm_mirror.SCRIPT_NAME, "../" .. pnpm_mirror.MAP_NAME, pnpm, "install", "--frozen-lockfile",
      "--config.confirmModulesPurge=false", "--store-dir", "../pnpm-store",
    }, { cwd = "build/daukle/" .. context.toolchain.name .. "/" .. SOURCE_WORKSPACE })
  end,
}

--- Points a derived `node_modules`, where a script step resolves, at a project's modules in the
--- source workspace.
local function link_source_modules(node, npm, root_instance, project, link)
  daukle.exec(node, { "./" .. pack.SCRIPT_NAME, "link-modules", npm,
                      "../" .. root_instance .. "/" .. SOURCE_WORKSPACE .. "/" .. project .. "node_modules", link })
end

--- Links this instance's modules, and for a member its root's too, since a step with
--- `fromWorkspaceRoot` runs the command from the root's derived directory.
local function use_source_workspace_modules(context, spec, node, npm)
  local root_instance = spec.workspace_root or context.toolchain.name
  run_task_of(root_instance .. ":source-workspace")
  if spec.workspace_root == nil then
    link_source_modules(node, npm, root_instance, "", "node_modules")
    return
  end
  link_source_modules(node, npm, root_instance, member_dir_in_root(context, spec) .. "/", "node_modules")
  link_source_modules(node, npm, root_instance, "", "../" .. root_instance .. "/node_modules")
end

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
    if declares_a_pack_script(spec) then
      if spec.workspace ~= nil or spec.workspace_root ~= nil then
        use_source_workspace_modules(context, spec, node, npm)
      else
        install_packages(context, spec)
      end
      run_declared_script(context, spec, "prepack")
      run_prepare(context, spec)
    end
    local argv = { "./" .. pack.SCRIPT_NAME, "stage", npm, context.root, publishable_manifest(context, spec), pack.STAGE_DIR, ".",
                   workspace_ranges.root_of_member(context, spec) }
    local result = daukle.exec(node, argv, { check = false })
    if result.code == pack.NO_ROOT_MANIFEST then
      install_and_link(context, spec)
      result = daukle.exec(node, argv, { check = false })
    end
    if result.code ~= 0 then error("node:pack: node exited with code " .. result.code, 0) end
    run_declared_script(context, spec, "postpack")
  end,
}

daukle.task{
  name = "node:migration-proof",
  dependsOn = { "node:tree", "node:pack" },
  run = function() end,
}

--- The derived directory a workspace root's tree installs the workspace in, rebuilt from what
--- daukle.toml renders.
local TREE_WORKSPACE = "tree-workspace"

--- The project's patch files copied to their paths in `TREE_WORKSPACE`, where its rendered workspace
--- file names them and pnpm, resolving them against it, reads them.
local function place_tree_patch_files(context, spec)
  local project = package_root(context)
  for _, file in ipairs(pnpm_workspace.patch_files(spec.workspace.settings or "")) do
    daukle.write{ path = TREE_WORKSPACE .. "/" .. file,
                  text = daukle.read(project == "." and file or project .. "/" .. file) }
  end
end

--- The workspace rebuilt in `TREE_WORKSPACE` from the rendered root and member package.json files,
--- the rendered workspace file, its patch files and the pinned lockfile, and installed there
--- through the mirror.
---
--- @implNote rebuilt rather than installed in the project's tree, because the proof runs while the
--- author's own package.json files are still at their paths; and its own workspace file is the
--- nearest one pnpm finds, so pnpm never walks up to the project's. A rebuilt member holds no
--- code, which a dependency tree does not read, so scripts are ignored.
local function install_tree_workspace(context, spec, root, pick)
  write_rendered_workspace(spec, TREE_WORKSPACE)
  place_tree_patch_files(context, spec)
  local pnpm = pnpm_behind_mirror(context, spec.pnpm_lock)
  daukle.exec(root:tool(pick.node), {
    "../" .. pnpm_mirror.SCRIPT_NAME, "../" .. pnpm_mirror.MAP_NAME, pnpm, "install", "--frozen-lockfile",
    "--ignore-scripts", "--config.confirmModulesPurge=false", "--store-dir", "../pnpm-store",
  }, { cwd = "build/daukle/" .. context.toolchain.name .. "/" .. TREE_WORKSPACE })
end

local function write_tree(root, pick, modules, workspace)
  daukle.exec(root:tool(pick.node), { "./" .. tree.SCRIPT_NAME, "--modules", modules, "--workspace", workspace })
end

--[[ @implNote the migration proof runs before core moves the old package.json
     aside, so tree installs on its own instead of depending on node:install.
     A workspace member reads its projects' modules from its root's rebuilt
     workspace, which the root's tree installs. ]]
daukle.task{
  name = "node:tree",
  run = function(context)
    local spec = settings.read(context)
    if spec.workspace ~= nil then
      local root, pick = provision_node(context, spec)
      install_tree_workspace(context, spec, root, pick)
      write_tree(root, pick, TREE_WORKSPACE .. "/node_modules", TREE_WORKSPACE)
      return
    end
    if spec.workspace_root ~= nil then
      run_task_of(spec.workspace_root .. ":tree")
      local workspace = "../" .. spec.workspace_root .. "/" .. TREE_WORKSPACE
      local root, pick = provision_node(context, spec)
      write_tree(root, pick, workspace .. "/" .. member_dir_in_root(context, spec) .. "/node_modules", workspace)
      return
    end
    local root, pick = install_packages(context, spec)
    daukle.exec(root:tool(pick.node), { "./" .. tree.SCRIPT_NAME })
  end,
}

--[[ @implNote --import is resolved against the working directory, which is the
     package root here, so the resolver is named relative to it and starts with
     "./" or "../" to stay a relative URL rather than a bare specifier. ]]
--- Runs the provisioned node with the resolver and these words and returns its exit code, so a
--- caller can fall back.
local function run_node(context, root, pick, words, env)
  local derived = derived_from_package_root(context)
  local resolver = (string.sub(derived, 1, 3) == "../" and "" or "./") .. derived .. "/"
                   .. runners.RESOLVER_NAME
  local argv = { "--import", resolver }
  for index = 1, #words do argv[#argv + 1] = words[index] end
  return daukle.exec(root:tool(pick.node), argv, { cwd = package_root(context), env = env, check = false }).code
end

--- Runs a module on the provisioned node and returns its exit code.
local function run_module(context, root, pick, module_path, args, env)
  local words = { module_path }
  for index = 1, #args do words[#words + 1] = args[index] end
  return run_node(context, root, pick, words, env)
end

--- A step's arguments with every `{ glob = ... }` expanded against the package root and every
--- `{ passed = true }` replaced by the script's passed arguments.
local function expanded(context, args, passed)
  local root = package_root(context)
  if root == "." then root = "" end
  local out = {}
  for _, argument in ipairs(args) do
    if type(argument) == "table" and argument.passed then
      for _, word in ipairs(passed or {}) do out[#out + 1] = word end
    elseif type(argument) == "table" then
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
    local code = run_module(context, root, pick, spec.entry, {})
    if code ~= 0 then error("node:run: " .. spec.entry .. " exited with code " .. code, 0) end
  end,
}

local function joined(first, second)
  local out = {}
  for _, item in ipairs(first) do out[#out + 1] = item end
  for _, item in ipairs(second) do out[#out + 1] = item end
  return out
end

local function takes_passed_arguments(steps)
  for _, step in ipairs(steps) do
    if step.kind == "attempt" then
      if takes_passed_arguments(step.attempt) or takes_passed_arguments(step.otherwise) then return true end
    end
    for _, argument in ipairs(step.args or step.paths or {}) do
      if type(argument) == "table" and argument.passed then return true end
    end
  end
  return false
end

local run_step_list

--- The task of a nested package's own instance: the instance a workspace's `members` maps the
--- directory to, else as core names an instance it migrated (D-248).
local function nested_task_name(context, spec, step)
  for _, member in ipairs(spec.workspace and spec.workspace.members or {}) do
    if member.dir == step.package then
      return member.instance .. ":" .. scripts.task_name_of(step.name)
    end
  end
  local root = package_root(context)
  local directory = root == "." and step.package or (root .. "/" .. step.package)
  return instance_name.of(directory) .. ":" .. scripts.task_name_of(step.name)
end

--- Runs a nested package's script as that package's own task, keeping why it failed for the
--- script's error, since a step reports only an exit code.
local function run_nested_script(context, spec, step)
  local ok, why = daukle.run_task(nested_task_name(context, spec, step))
  if ok then return 0 end
  spec.nested_failure = why
  return 1
end

--- Runs one step and returns its exit code. `extra` is appended to its words; `passed` fills
--- each `{ passed = true }`.
local function run_step(context, spec, step, extra, passed)
  local runner = derived_from_package_root(context) .. "/"
  if step.kind == "attempt" then
    local code = run_step_list(context, spec, step.attempt, {}, passed)
    if code == 0 then return 0 end
    return run_step_list(context, spec, step.otherwise, extra, passed)
  end
  spec.nested_failure = nil
  if step.kind == "script" and step.package ~= nil then return run_nested_script(context, spec, step) end
  if step.kind == "script" then
    -- read() has already refused a reference to no script and a cycle, so a
    -- second check here would be a second place for the rule to disagree.
    for other = 1, #spec.scripts do
      if spec.scripts[other].name == step.name then
        return run_steps(context, spec, spec.scripts[other], joined(expanded(context, step.args, passed), extra))
      end
    end
  end
  local root, pick = provision_node(context, spec)
  if step.kind == "module" then
    return run_module(context, root, pick, step.name, expanded(context, joined(step.args, extra), passed), step.env)
  end
  if step.kind == "node" then
    return run_node(context, root, pick, expanded(context, joined(step.args, extra), passed), step.env)
  end
  if step.kind == "remove" then
    local argv = { step.recursive and "1" or "0", step.force and "1" or "0" }
    for _, path in ipairs(expanded(context, joined(step.paths, extra), passed)) do argv[#argv + 1] = path end
    return run_module(context, root, pick, runner .. runners.REMOVER_NAME, argv)
  end
  if step.kind == "echo" then
    return run_module(context, root, pick, runner .. runners.ECHO_NAME, expanded(context, joined(step.args, extra), passed))
  end
  local argv = { step.name, step.binName or "" }
  for _, argument in ipairs(expanded(context, joined(step.args, extra), passed)) do argv[#argv + 1] = argument end
  return run_module(context, root, pick, bin_runner_directory(context, spec, step) .. runners.BIN_RUNNER_NAME, argv, step.env)
end

--- Runs steps until one fails, `extra` going to the last, and returns the exit code: 0, or the
--- failing step's, which is what `&&` stops on and `||` falls back on.
function run_step_list(context, spec, steps, extra, passed)
  for index, step in ipairs(steps) do
    local code = run_step(context, spec, step, index == #steps and extra or {}, passed)
    if code ~= 0 then return code end
  end
  return 0
end

--- Runs a script's steps and returns the exit code. `appended` goes to the end of the last step,
--- which is where npm puts the words after `npm run <name> --` (D-244), unless the script came
--- from a `sh -c`, whose `"$@"` words take them instead (D-249).
function run_steps(context, spec, script, appended)
  if takes_passed_arguments(script.steps) then
    return run_step_list(context, spec, script.steps, {}, appended or {})
  end
  return run_step_list(context, spec, script.steps, appended or {}, nil)
end

function run_script_steps(context, spec, script)
  local code = run_steps(context, spec, script)
  if code ~= 0 and spec.nested_failure ~= nil then
    error(string.format('scripts."%s" failed: %s', script.name, spec.nested_failure), 0)
  end
  if code ~= 0 then error(string.format('scripts."%s" failed: a step exited with code %d', script.name, code), 0) end
end

-- The NAME is closed over and the script is looked up at task time, because the
-- chunk saw the primary manifest alone and a daukle.lua overlay may have
-- changed what the script does by the time it runs.
local function run_script(script_name)
  return function(context)
    local spec = settings.read(context)
    for index = 1, #spec.scripts do
      if spec.scripts[index].name == script_name then
        run_script_steps(context, spec, spec.scripts[index])
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
