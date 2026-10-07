daukle.plugin{
  api = 1,
  uses = { "provision", "exec", "read", "parse" },
  exports = { "lib/runtimes" },
}

local runtimes = daukle.require("lib/runtimes")
local scripts = daukle.require("lib/scripts")

local RESOLVER_NAME = "__daukle_resolver__.mjs"
local BIN_RUNNER_NAME = "__daukle_bin__.mjs"

--[[ @implNote three of these four guards return a working module when they are
     wrong, which is why the suite compares every specifier against what node
     resolves natively from a twin tree rather than asserting that a module
     loaded. The anchor is never created: createRequire and pathToFileURL both
     accept a path to a file that does not exist, and it is only there to name
     the directory resolution starts from. ]]
local RESOLVER = [==[
import { createRequire, registerHooks } from "node:module";
import { pathToFileURL, fileURLToPath } from "node:url";
import { dirname, join, resolve as resolvePath } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const anchor = join(here, "__daukle_anchor__.js");
const asIfImportedFrom = pathToFileURL(anchor).href;
const requireFromDerived = createRequire(anchor);
const installedUnder = pathToFileURL(join(here, "node_modules")).href + "/";
const projectUnder = pathToFileURL(resolvePath(here, "..", "..", "..")).href + "/";

function isBare(specifier) {
  if (specifier === "") return false;
  if (specifier[0] === "." || specifier[0] === "/") return false;
  return !/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(specifier);
}

function belongsToThisProject(parentURL) {
  if (typeof parentURL !== "string") return false;
  if (!parentURL.startsWith(projectUnder)) return false;
  return !parentURL.startsWith(installedUnder);
}

// Iterated rather than indexed, because the shape is not one thing: node
// v22.15.0 hands an Array to an ESM resolve and a Set to a CommonJS one, and
// v26.3.1 hands an Array to both. A branch per shape would leave whichever one
// the running node does not use untested, and includes() over a Set answers
// false rather than throwing, so the wrong branch would be silent.
function hasCondition(conditions, name) {
  if (conditions == null) return false;
  for (const condition of conditions) if (condition === name) return true;
  return false;
}

// A descendant gets the hook through NODE_OPTIONS, which has to name an
// absolute file URL: node refuses an absolute PATH to --import on Windows and
// resolves a relative one against each process's own working directory, which
// would kill an unrelated node started elsewhere rather than merely shadow it.
// Prepended rather than assigned, so whatever the user exported survives, and
// skipped when it is already there, so it does not grow a flag per generation.
const inheritedOptions = process.env.NODE_OPTIONS;
if (!inheritedOptions) {
  process.env.NODE_OPTIONS = "--import " + import.meta.url;
} else if (!inheritedOptions.includes(import.meta.url)) {
  process.env.NODE_OPTIONS = "--import " + import.meta.url + " " + inheritedOptions;
}

let resolving = false;

registerHooks({
  resolve(specifier, context, nextResolve) {
    if (resolving || !isBare(specifier) || !belongsToThisProject(context.parentURL)) {
      return nextResolve(specifier, context);
    }
    if (hasCondition(context.conditions, "import")) {
      return nextResolve(specifier, { ...context, parentURL: asIfImportedFrom });
    }
    resolving = true;
    try {
      return { url: pathToFileURL(requireFromDerived.resolve(specifier)).href, shortCircuit: true };
    } finally {
      resolving = false;
    }
  },
});
]==]

--[[ @implNote an npm bin shim is nothing but "<node> <package>/<bin field>",
     written three times on Windows (sh, .cmd, .ps1) and once as a symlink
     elsewhere, and EVERY shape falls back to a node on PATH when none sits
     beside it, which in a daukle project is the host's node or none at all.
     So the shims are not used: the bin field is read here, by the node this
     toolchain provisioned, with the resolver already loaded through --import.
     That needs no per-platform branch and no cmd.exe.

     Read with fs rather than through a specifier, because a package whose
     "exports" map does not list "./package.json" refuses to resolve it, and
     a direct dependency is at node_modules/<name> by npm's own layout. ]]
local BIN_RUNNER = [==[
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const [packageName, binName, ...rest] = process.argv.slice(2);
const packageRoot = join(here, "node_modules", packageName);

let manifest;
try {
  manifest = JSON.parse(readFileSync(join(packageRoot, "package.json"), "utf8"));
} catch (cause) {
  throw new Error(`"${packageName}" is not installed, so it has no command to run`, { cause });
}

const bin = manifest.bin;
const wanted = binName || packageName;
let target;
if (typeof bin === "string") {
  if (binName && binName !== packageName) {
    throw new Error(`"${packageName}" publishes one command and it is not "${binName}"`);
  }
  target = bin;
} else if (bin && typeof bin === "object") {
  target = bin[wanted];
  if (typeof target !== "string") {
    const offered = Object.keys(bin).sort().join(", ");
    throw new Error(
      `"${packageName}" publishes no command called "${wanted}": set "binName" to one of ${offered}`,
    );
  }
} else {
  throw new Error(`"${packageName}" publishes no command, so there is nothing to run`);
}

// The bin reads its own name and arguments out of argv, exactly as it would
// behind npm's shim, so argv is rewritten before it is imported rather than
// after it has already read the wrong one.
const resolved = resolve(packageRoot, target);
process.argv = [process.argv[0], resolved, ...rest];
await import(pathToFileURL(resolved).href);
]==]

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
      [RESOLVER_NAME] = RESOLVER,
      [BIN_RUNNER_NAME] = BIN_RUNNER,
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
  local argv = { "--import", "./" .. RESOLVER_NAME, module_path }
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

local function run_steps(context, spec, script, seen)
  for index = 1, #script.steps do
    local step = script.steps[index]
    if step.kind == "script" then
      local target
      for other = 1, #spec.scripts do
        if spec.scripts[other].name == step.name then target = spec.scripts[other] end
      end
      if target == nil then
        error(string.format('scripts."%s" runs "%s", which is not a declared script',
                            script.name, step.name), 0)
      end
      if seen[step.name] then
        error(string.format('scripts."%s" runs "%s", which runs itself again', script.name,
                            step.name), 0)
      end
      seen[step.name] = true
      run_steps(context, spec, target, seen)
      seen[step.name] = nil
    elseif step.kind == "module" then
      local root, pick = provision_node(context, spec)
      run_module(root, pick, context.root .. "/" .. step.name, step.args)
    else
      local root, pick = provision_node(context, spec)
      local argv = { step.name, step.binName or "" }
      for at = 1, #step.args do argv[#argv + 1] = step.args[at] end
      run_module(root, pick, "./" .. BIN_RUNNER_NAME, argv)
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
        run_steps(context, spec, spec.scripts[index], { [script_name] = true })
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
