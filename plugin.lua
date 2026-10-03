daukle.plugin{ api = 1, uses = { "provision", "exec" }, exports = { "lib/runtimes" } }

local runtimes = daukle.require("lib/runtimes")

local RESOLVER_NAME = "__daukle_resolver__.mjs"

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

local KNOWN_KEYS = { version = true, entry = true, packages = true, devPackages = true }

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

local function entry_of(config)
  local entry = config.entry
  if entry == nil then
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
  return {
    version = version_of(context),
    entry = entry_of(config),
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

daukle.task{
  name = "node:run",
  dependsOn = { "node:install" },
  run = function(context)
    local spec = read(context)
    local root, pick = provision_node(context, spec)
    -- Relative, and correct because a task's working directory is the derived
    -- directory the resolver was generated into. The resolver itself is what
    -- hands descendants the absolute form, since context.root is "../../.."
    -- and a plugin has no absolute path to the project at all.
    daukle.exec(root:tool(pick.node),
                { "--import", "./" .. RESOLVER_NAME, context.root .. "/" .. spec.entry })
  end,
}
