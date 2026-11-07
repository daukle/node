local runtimes = daukle.require("lib/runtimes")
local translate = daukle.require("lib/translate")
local engines = daukle.require("lib/engines")
local tree = daukle.require("lib/tree")
local paths = daukle.require("lib/paths")
local npm_errors = daukle.require("lib/npm_errors")
local npmrc = daukle.require("lib/npmrc")
local pack = daukle.require("lib/pack")
local published = daukle.require("lib/published")
local scripts = daukle.require("lib/scripts")
local nested = daukle.require("lib/nested")
local package_fields = daukle.require("lib/package_fields")
local frontend_pom = daukle.require("lib/frontend_pom")
local pnpm_workspace = daukle.require("lib/pnpm_workspace")

local PROBE_NAME = "__daukle_probe__.mjs"

--[[ @implNote the bins are read from the probe's own install so that the
     answer is npm's layout, not a guess from names. ]]
local PROBE = [==[
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const modules = process.argv[3] ? resolve(process.argv[3]) : join(here, "node_modules");

/** @implNote no accepted form ends in a slash: git classifies a POSIX symlink as a file, so a directory-only pattern does not ignore the link node:install places (Git for Windows treats a junction as a directory, which hides this there). */
const ROOT_ENTRIES = [
  { fact: "node_modules", name: "node_modules",
    forms: (prefixFromIgnoreFile) => ["node_modules", "**/node_modules", "/" + prefixFromIgnoreFile + "node_modules"] },
  { fact: "package_json", name: "package.json",
    forms: (prefixFromIgnoreFile) => ["package.json", "**/package.json", "/" + prefixFromIgnoreFile + "package.json"] },
];
const reincludedBy = {};
function globSource(glob) {
  let source = "";
  for (let index = 0; index < glob.length; index++) {
    if (glob.startsWith("**/", index)) { source += "(?:.*/)?"; index += 2; }
    else if (glob.startsWith("/**", index) && index + 3 === glob.length) { source += "/.*"; index += 2; }
    else if (glob[index] === "*") source += "[^/]*";
    else if (glob[index] === "?") source += "[^/]";
    else source += glob[index].replace(/[.+^${}()|\]]/g, "\\$&");
  }
  return source;
}
/** @implNote errs toward "may": an escape or a bracket class is not matched at all, a trailing slash is ignored although a POSIX link is a file, and case is ignored because a Windows or macOS checkout does. A false "may" costs the user one line; a false "cannot" lets generated files be committed. */
function mayUnignore(pattern, entry, prefixFromIgnoreFile) {
  if (/[\\[]/.test(pattern)) return true;
  const glob = pattern.replace(/\/+$/, "").replace(/^\//, "");
  const path = glob.includes("/") ? prefixFromIgnoreFile + entry.name : entry.name;
  return new RegExp("^" + globSource(glob) + "$", "i").test(path);
}
function readIgnoreLines(path) {
  try { return readFileSync(path, "utf8").replace(/^\uFEFF/, "").split("\n"); }
  catch (error) { if (error.code === "ENOENT") return []; throw error; }
}
/** @implNote git keeps leading whitespace and every trailing character but an unescaped space, a tab included. */
function patternLine(raw) {
  return raw.replace(/\r$/, "").replace(/(?<!\\) +$/, "");
}
function applyIgnore(path, prefixFromIgnoreFile) {
  for (const raw of readIgnoreLines(path)) {
    const line = patternLine(raw);
    if (line === "" || line.startsWith("#")) continue;
    const negated = line.startsWith("!");
    const pattern = negated ? line.slice(1) : line;
    for (const entry of ROOT_ENTRIES) {
      if (negated && mayUnignore(pattern, entry, prefixFromIgnoreFile)) {
        reincludedBy[entry.fact] = { line, file: path };
      } else if (!negated && entry.forms(prefixFromIgnoreFile).includes(pattern)) {
        delete reincludedBy[entry.fact];
      }
    }
  }
}
const depth = (process.argv[2] ?? "").split("/").filter(Boolean).length;
const segments = process.cwd().split(/[\\/]/).filter(Boolean);
try {
  for (let level = depth; level >= 0; level--) {
    const prefixFromIgnoreFile = level === 0 ? "" : segments.slice(segments.length - level).join("/") + "/";
    applyIgnore("../".repeat(level) + ".gitignore", prefixFromIgnoreFile);
  }
} catch (error) {
  for (const entry of ROOT_ENTRIES) reincludedBy[entry.fact] = { unreadable: String(error.message ?? error) };
}
/** @implNote every package at the top of node_modules, scoped ones included, in npm's own order: arborist links bins sorted by depth then by localeCompare of the path, and the first package to claim a command keeps it (`#linkAllBins`, bin-links' `seen`), so a direct dependency has no priority over a transitive one. */
function topLevelPackages() {
  const names = [];
  let entries;
  try { entries = readdirSync(modules); } catch { return names; }
  for (const entry of entries) {
    if (entry.startsWith(".")) continue;
    if (!entry.startsWith("@")) { names.push(entry); continue; }
    for (const scoped of readdirSync(join(modules, entry))) names.push(entry + "/" + scoped);
  }
  return names.sort((left, right) => ("node_modules/" + left).localeCompare("node_modules/" + right, "en"));
}
const bins = {};
for (const name of topLevelPackages()) {
  let manifest;
  try { manifest = JSON.parse(readFileSync(join(modules, name, "package.json"), "utf8")); }
  catch { continue; }
  const map = typeof manifest.bin === "object" && manifest.bin !== null;
  const commands = typeof manifest.bin === "string"
    ? [name.replace(/^@[^/]+\//, "")]
    : Object.keys(map ? manifest.bin : {});
  for (const command of commands) bins[command] ??= [{ name, map }];
}
process.stdout.write(JSON.stringify({ bins, reincludedBy }));
]==]

local function within(dir, name)
  if dir == nil then return name end
  return dir .. "/" .. name
end

local function derived(context, name)
  return "build/daukle/" .. context.instance .. "/" .. name
end

local function provision(context, version)
  local pick = runtimes.for_host{ os = context.host.os, arch = context.host.arch, version = version }
  local root = daukle.provision{ url = pick.url, sha256 = pick.sha256, as = "node " .. pick.version }
  return root, pick
end

local function json_object(map)
  local names = {}
  for name in pairs(map or {}) do names[#names + 1] = name end
  table.sort(names)
  local parts = {}
  for _, name in ipairs(names) do parts[#parts + 1] = '"' .. name .. '": "' .. map[name] .. '"' end
  return "{" .. table.concat(parts, ", ") .. "}"
end

local function proof_of(context, config)
  local compare = { {
    old = derived(context, "migrate-old/" .. tree.OUTPUT_NAME),
    new = derived(context, tree.OUTPUT_NAME),
    as = "bytes",
  } }
  if config[published.KEY] == nil then return { task = context.instance .. ":tree", compare = compare } end
  -- the packed package.json is rendered rather than the author's bytes, so it is equal by value (ruling 5.1)
  compare[2] = { old = derived(context, "migrate-old/" .. pack.TARBALL_NAME),
                 new = derived(context, pack.TARBALL_NAME), as = "archive-json" }
  return { task = context.instance .. ":migration-proof", compare = compare }
end

local PUBLISHED_ROW = "7. Packing and publishing: `scripts` in the packed manifest"

--- A blocker for each script a packed package publishes that its steps do not render back to
--- exactly, because the packed manifest is rendered from the steps (ruling 5.2). Called only once
--- every command resolved, since scripts.read refuses a step that still names a bare command.
local function unpublishable_scripts(config, original, where)
  local blockers = {}
  if config[published.KEY] == nil or type(original) ~= "table" then return blockers end
  for _, script in ipairs(scripts.read({ scripts = config.scripts })) do
    local rendered = published.render(script.steps)
    if rendered ~= original[script.name] then
      blockers[#blockers + 1] = { construct = 'scripts."' .. script.name .. '"', where = where,
                                  why = string.format('is published in the packed package.json as "%s",'
                                        .. ' which is not the "%s" the package declares',
                                        rendered, tostring(original[script.name])),
                                  surface = "NPM-SURFACE.md: " .. PUBLISHED_ROW }
    end
  end
  return blockers
end

local function has_any(map)
  return map ~= nil and next(map) ~= nil
end

--- The dependencies, handed to daukle/npm's translator, or daukle/pnpm's for a pnpm project, rather
--- than written here: that block holds the ranges and its pin file the closure, so node's own block
--- carries neither.
---
--- @implNote a workspace member hands nothing over and keeps its ranges in its own block: the
--- root's pins cover every member (spec 4.2).
local function dependencies_of(config, lock_text)
  local packages, dev_packages, npm_config = config.packages, config.devPackages, config.npmConfig
  local npmrc_where, overrides, pnpm = config.npmrc, config.overrides, config.pnpm
  config.npmConfig, config.npmrc, config.pnpm = nil, nil, nil
  if type(config[pnpm_workspace.KEY]) == "string" then return {} end
  config.packages, config.devPackages, config.overrides = nil, nil, nil
  if lock_text == nil or not (has_any(packages) or has_any(dev_packages)) then return {} end
  if pnpm ~= nil then
    return { { kind = "dependencies", id = "pnpm",
               config = { version = config.version, pnpm = pnpm, packages = packages or {},
                          devPackages = dev_packages or {}, lock = lock_text, overrides = overrides } } }
  end
  return { { kind = "dependencies", id = "npm",
             config = { version = config.version, packages = packages or {},
                        devPackages = dev_packages or {}, lock = lock_text,
                        npmConfig = has_any(npm_config) and npm_config or nil, npmrc = npmrc_where,
                        overrides = overrides } } }
end

local function result(context, config, blockers, owned, lock_text)
  local foreign = dependencies_of(config, lock_text)
  return {
    manifest = { toolchains = { [context.instance] = config } },
    foreign = foreign,
    blockers = blockers,
    owned = owned,
    proof = proof_of(context, config),
  }
end

local PROBE_IDENTITY ='"name": "daukle-migrate-probe", "version": "0.0.0"'

--- Where the original workspace's install places each project's modules, relative to it: pnpm
--- reads `--modules-dir` against every importer, the root's included.
local WORKSPACE_MODULES_DIR = "build/daukle/migrate-workspace/node_modules"

--- Whether the root's run installed the original workspace, read from the root's own modules
--- directory, which pnpm writes `.modules.yaml` into even where a member declares no dependency.
local function is_workspace_installed(root)
  return daukle.list(within(root.dir, WORKSPACE_MODULES_DIR)) ~= nil
end

local function npm_install_for_probe(context, root, pick, config, env)
  daukle.write{ path = "migrate-probe/package.json", text = '{' .. PROBE_IDENTITY
                .. ', "private": true, "dependencies": ' .. json_object(config.packages)
                .. ', "devDependencies": ' .. json_object(config.devPackages)
                .. (config.overrides == nil and "" or (', "overrides": ' .. config.overrides)) .. '}\n' }
  local install = daukle.exec(root:tool(pick.node), { root:path(pick.npm), "install",
                                                      "--ignore-scripts", "--include=dev" },
                              { cwd = derived(context, "migrate-probe"), capture = true, env = env,
                                check = false })
  if install.code == 0 then return nil end
  local failure = npm_errors.of_install(install.stderr, install.code)
  if not failure.resolution then error("npm install failed: " .. failure.message, 0) end
  return failure.message
end

--- The probe's facts: each command the package's modules provide, and the ignore facts. A
--- workspace member installs nothing of its own and reads the modules its root's install placed.
---
--- @implNote the probe script still runs after a failed install, because the ignore facts need no
--- node_modules and the report should carry them beside the install failure.
local function probe(context, config, env, is_member)
  local root, pick = provision(context, config.version)
  local unresolved = nil
  if not is_member then unresolved = npm_install_for_probe(context, root, pick, config, env) end
  daukle.write{ path = "migrate-probe/" .. PROBE_NAME, text = PROBE }
  local argv = { paths.climb_from(context.dir) .. derived(context, "migrate-probe/" .. PROBE_NAME),
                 paths.climb_from(context.dir) }
  if is_member then argv[3] = WORKSPACE_MODULES_DIR end
  local answer = daukle.exec(root:tool(pick.node), argv, { cwd = context.dir or ".", capture = true })
  return daukle.json_parse(answer.stdout), unresolved
end

local NPM_CONFIGURATION = "configures npm in a way this toolchain does not carry over"
local VERSION_FILES = { ".nvmrc", ".node-version" }
local VERSION_FILE_ROW = "1. The runtime: a node version file (`.nvmrc`, `.node-version`)"
local FRONTEND_ROW = "1. The runtime: a node `frontend-maven-plugin` installs (`nodeVersion`)"

local function first_line(text)
  for line in string.gmatch(text or "", "[^\r\n]+") do
    local trimmed = string.match(line, "^%s*(.-)%s*$")
    if trimmed ~= "" and string.sub(trimmed, 1, 1) ~= "#" then return trimmed end
  end
  return nil
end

local function pinned_versions()
  local out = {}
  for index, release in ipairs(runtimes.releases()) do out[index] = release.version end
  return table.concat(out, ", ")
end

local function contains(list, value)
  for _, item in ipairs(list) do if item == value then return true end end
  return false
end

--- Whether even the newest node a version can name is older than the oldest this plugin provisions.
local function is_below_floor(version)
  local floor = {}
  for piece in string.gmatch(runtimes.floor, "%d+") do floor[#floor + 1] = tonumber(piece) end
  local index = 1
  for piece in string.gmatch(version, "%d+") do
    local number = tonumber(piece)
    if number ~= floor[index] then return number < floor[index] end
    index = index + 1
  end
  return false
end

local function unsatisfied_why(pin, version)
  if is_below_floor(version) then
    return string.format('%s %s, below %s, the oldest node this plugin provisions: its resolver needs'
                         .. ' module.registerHooks, which older nodes lack', pin.names, pin.text,
                         runtimes.floor)
  end
  return string.format('%s %s, and no pinned node satisfies it together with engines: this plugin'
                       .. ' pins %s', pin.names, pin.text, pinned_versions())
end

--- Every node version the project pins outside package.json: each version file, and each
--- `nodeVersion` a frontend-maven-plugin in the pom.xml beside it installs.
local function version_pins(context, files)
  local pins = {}
  for _, name in ipairs(VERSION_FILES) do
    if files.exists[name] then
      local where = within(context.dir, name)
      pins[#pins + 1] = { construct = name, where = where, text = first_line(daukle.read(where)),
                          names = "names node", surface = VERSION_FILE_ROW }
    end
  end
  if files.exists[frontend_pom.NAME] then
    local where = within(context.dir, frontend_pom.NAME)
    for _, pin in ipairs(frontend_pom.node_pins(daukle.read(where))) do
      pins[#pins + 1] = { construct = frontend_pom.CONSTRUCT, where = where, text = pin.version,
                          unresolved = pin.unresolved, names = "installs node", surface = FRONTEND_ROW }
    end
  end
  return pins
end

local function pin_problem(pin)
  if pin.unresolved ~= nil then
    return string.format('installs node %s, a property this pom does not define, so which node Maven'
                         .. ' builds the package with is unknown', pin.unresolved)
  end
  local version = pin.text and string.match(pin.text, "^[vV]?(%d+[%.%d]*)$")
  if version == nil or string.match(version, "^%d+%.?%d*%.?%d*$") == nil then
    return string.format('names "%s", which is an alias a version manager looks up rather than a version',
                         tostring(pin.text))
  end
  return nil, version
end

--- The candidates narrowed by each node version pin, read with nvm's meaning: a partial version
--- is the newest matching release and an exact one is exact; an alias is a blocker (D-242).
local function narrowed_by_version_files(context, files, candidates)
  local blockers = {}
  for _, pin in ipairs(version_pins(context, files)) do
    local problem, version = pin_problem(pin)
    if problem ~= nil then
      blockers[#blockers + 1] = { construct = pin.construct, where = pin.where, why = problem,
                                  surface = "NPM-SURFACE.md: " .. pin.surface }
    else
      local allowed = engines.satisfying(version, nil) or {}
      local kept = {}
      for _, candidate in ipairs(candidates) do
        if contains(allowed, candidate) then kept[#kept + 1] = candidate end
      end
      if #kept == 0 then
        blockers[#blockers + 1] = { construct = pin.construct, where = pin.where,
                                    why = unsatisfied_why(pin, version),
                                    surface = "NPM-SURFACE.md: " .. pin.surface }
      end
      candidates = kept
    end
  end
  return candidates, blockers
end

local NESTED_PACKAGE = "is a package.json below the package root, which node reads for the resolution"
                       .. " of the files under it (its \"imports\" map, a self-reference by name),"
                       .. " and the toolchain resolves a bare specifier from the derived directory instead"
local NESTED_ROW = "2. Module resolution: a nested `package.json` below the package root"
local UNRESOLVED_ROW = "3. Dependencies: the declared dependencies do not resolve"

local FOREIGN_LOCKFILE = "pins this project's dependencies for another package manager, and the"
                         .. " migration would install with npm and drop those pins"
local FOREIGN_LOCKFILE_ROW = "4. Install, lockfile and registry configuration: another package"
                             .. " manager's lockfile (`yarn.lock`, `pnpm-lock.yaml`, `bun.lock`, `bun.lockb`)"

local LOCKFILE_ROW = "4. Install, lockfile and registry configuration: a committed `package-lock.json`"

--- The first npm line that says why `npm ci` refused, for a blocker's text.
local function npm_refusal(stderr)
  local lines = {}
  for line in string.gmatch(stderr or "", "npm error ([^\r\n]+)") do
    if line ~= "" and string.match(line, "^code ") == nil then lines[#lines + 1] = line end
    if #lines == 2 then break end
  end
  return table.concat(lines, " ")
end

--- The newest candidate node whose bundled npm accepts the committed lockfile, measured with
--- `npm ci --dry-run`: npm 11 refuses some lockfiles npm 10 wrote (D-239, ruled 2026-11-06).
---
--- @return string|nil version, string|nil why the newest npm's refusal when none accepts it
local function accepting_version(context, candidates, where, lock_where, env)
  daukle.write{ path = "migrate-lockcheck/package.json", text = daukle.read(where) }
  daukle.write{ path = "migrate-lockcheck/package-lock.json", text = daukle.read(lock_where) }
  local newest_refusal
  for _, version in ipairs(candidates) do
    local root, pick = provision(context, version)
    local check = daukle.exec(root:tool(pick.node), { root:path(pick.npm), "ci", "--dry-run", "--ignore-scripts",
                                                      "--no-audit", "--no-fund" },
                              { cwd = derived(context, "migrate-lockcheck"), capture = true, env = env,
                                check = false })
    if check.code == 0 then return version end
    newest_refusal = newest_refusal or string.format("npm %s refuses it: %s", pick.npm_version,
                                                     npm_refusal(check.stderr))
  end
  return nil, newest_refusal
end

local ROOT_ENTRIES_ROW = "2. Module resolution: a tool that resolves `node_modules` or reads `package.json` itself"
local ROOT_ENTRIES = {
  { fact = "node_modules", line = "node_modules", name = "node_modules", placed = "as a link to" },
  { fact = "package_json", line = "/package.json", name = "package.json", placed = "as a copy of" },
}

--- Why a `.gitignore` can still list a placed entry, which node:install's `info/exclude` line
--- cannot overrule, since git ranks every `.gitignore` above it.
local function root_entry_remedy(entry, reincluded)
  if reincluded.unreadable ~= nil then
    return "a .gitignore that cannot be read could re-include it (" .. reincluded.unreadable .. ")"
  end
  return "the negation " .. reincluded.line .. " in " .. reincluded.file .. " can re-include it:"
         .. " remove that negation, or repeat " .. entry.line .. " below it"
end

local REFUSED_FILES = {
  { name = "npm-shrinkwrap.json", why = NPM_CONFIGURATION,
    row = "4. Install, lockfile and registry configuration: an `npm-shrinkwrap.json`" },
  { name = "yarn.lock", why = FOREIGN_LOCKFILE, row = FOREIGN_LOCKFILE_ROW },
  { name = "pnpm-lock.yaml", why = FOREIGN_LOCKFILE, row = FOREIGN_LOCKFILE_ROW },
  { name = "bun.lock", why = FOREIGN_LOCKFILE, row = FOREIGN_LOCKFILE_ROW },
  { name = "bun.lockb", why = FOREIGN_LOCKFILE, row = FOREIGN_LOCKFILE_ROW },
  { name = pnpm_workspace.NAME, why = "declares a pnpm workspace, which this toolchain migrates only for a"
                                       .. " project that installs with pnpm: a committed pnpm-lock.yaml and a"
                                       .. " packageManager naming pnpm",
    row = package_fields.ROWS.workspaces },
}

local SKIPPED_DIRECTORIES = { node_modules = true, [".git"] = true }

local function below(relative, name)
  if relative == "" then return name end
  return relative .. "/" .. name
end

--[[ @implNote read with daukle.list rather than by the node probe, so these facts
     are found even when translation already blocked and node is never fetched.
     A link is never descended into, as the walk node made did not either. ]]
local function file_facts(context)
  local facts = { exists = {}, nested = {}, unreadable = {} }
  local function walk(relative)
    local entries, why = daukle.list(relative == "" and (context.dir or ".") or within(context.dir, relative))
    if entries == nil then
      if why ~= nil then facts.unreadable[#facts.unreadable + 1] = { path = relative == "" and "." or relative, why = why } end
      return
    end
    for _, entry in ipairs(entries) do
      local path = below(relative, entry.name)
      if relative == "" then facts.exists[entry.name] = true end
      if entry.kind == "directory" then
        if not SKIPPED_DIRECTORIES[entry.name] and path ~= "build/daukle" then walk(path) end
      elseif relative ~= "" and entry.name == "package.json" then
        facts.nested[#facts.nested + 1] = path
      end
    end
  end
  walk("")
  table.sort(facts.nested)
  return facts
end

local PNPM_LOCK = "pnpm-lock.yaml"

--- Whether the project installs with pnpm: its lockfile committed, its `packageManager` naming
--- pnpm, and no npm lockfile beside it to say otherwise.
local function is_pnpm_project(files, config)
  return config.pnpm ~= nil and files.exists[PNPM_LOCK] == true and not files.exists["package-lock.json"]
end

--- Why a `packageManager` naming pnpm cannot be handed to daukle/pnpm, or nil when it can.
local function pnpm_blockers(context, files, config, where)
  if config.pnpm == nil or is_pnpm_project(files, config) then return {} end
  local why = files.exists["package-lock.json"]
              and "names pnpm, and the project also commits a package-lock.json, so which closure it installs is ambiguous"
              or "names pnpm, and the project commits no pnpm-lock.yaml for daukle/pnpm to pin"
  return { { construct = '"packageManager"', where = where, why = why,
             surface = "NPM-SURFACE.md: " .. FOREIGN_LOCKFILE_ROW } }
end

local OWNED_BY_A_PNPM_PROJECT = { [PNPM_LOCK] = true, [pnpm_workspace.NAME] = true }

local function is_refused_file(facts, refused)
  return facts.exists[refused.name] and not (OWNED_BY_A_PNPM_PROJECT[refused.name] and facts.installs_with_pnpm)
end

local function file_blockers(context, facts, blockers)
  for _, refused in ipairs(REFUSED_FILES) do
    if is_refused_file(facts, refused) then
      blockers[#blockers + 1] = { construct = refused.name, where = within(context.dir, refused.name),
                                  why = refused.why, surface = "NPM-SURFACE.md: " .. refused.row }
    end
  end
  for _, path in ipairs(facts.nested) do
    blockers[#blockers + 1] = { construct = path, where = within(context.dir, path), why = NESTED_PACKAGE,
                                surface = "NPM-SURFACE.md: " .. NESTED_ROW }
  end
  for _, directory in ipairs(facts.unreadable) do
    blockers[#blockers + 1] = { construct = directory.path, where = within(context.dir, directory.path),
                                why = "is a directory the migrator cannot list (" .. directory.why
                                      .. "), so a nested package.json in it cannot be ruled out",
                                surface = "NPM-SURFACE.md: " .. NESTED_ROW }
  end
  return blockers
end

--- Whether every package of a lockfile names its tarball and digest, which pinning needs:
--- npm leaves `resolved` and `integrity` out of some entries of some lockfiles.
local function is_complete_lock(lock)
  if (lock.lockfileVersion or 1) < 2 or type(lock.packages) ~= "table" then return false end
  for path, entry in pairs(lock.packages) do
    if path ~= "" and not entry.inBundle and not entry.link
       and (type(entry.resolved) ~= "string" or type(entry.integrity) ~= "string") then
      return false
    end
  end
  return true
end

--- The closure the migrated project pins: the project's own lockfile when it is complete, so
--- it installs exactly what it did, and otherwise the one the probe's install wrote, which the
--- proof then compares against the old build.
local function lock_of(context, files)
  if files.exists["package-lock.json"] then
    local text = daukle.read(within(context.dir, "package-lock.json"))
    if is_complete_lock(daukle.json_parse(text)) then return text end
  end
  return daukle.read(derived(context, "migrate-probe/package-lock.json"))
end

--- The `.npmrc` beside the package.json, read, or an empty one when there is none.
local function npmrc_of(context, files)
  local where = within(context.dir, npmrc.NAME)
  if not files.exists[npmrc.NAME] then return { config = {}, blockers = {}, where = where } end
  local parsed = npmrc.read(daukle.read(where), where)
  parsed.where = where
  return parsed
end

local function has_dependencies(config)
  return has_any(config.packages) or has_any(config.devPackages)
end

--- Takes the nested package.json files that only mark a format boundary out of `facts.nested`,
--- returning them as `nestedPackages` entries and the paths the migration moves aside.
local function take_boundaries(context, facts)
  local entries, paths_taken, kept = {}, {}, {}
  for _, path in ipairs(facts.nested) do
    local directory = string.sub(path, 1, #path - #"/package.json")
    local entry = nested.directory_problem(directory) == nil
                  and nested.boundary_of(daukle.read(within(context.dir, path)))
    if entry then
      entries[directory] = entry
      paths_taken[#paths_taken + 1] = within(context.dir, path)
    else
      kept[#kept + 1] = path
    end
  end
  facts.nested = kept
  return next(entries) ~= nil and entries or nil, paths_taken
end

local function directory_of(path)
  return string.sub(path, 1, #path - #"/package.json")
end

local function nested_directories(facts)
  local directories = {}
  for index, path in ipairs(facts.nested) do directories[index] = directory_of(path) end
  return directories
end

local function is_at_or_below(directory, path)
  return path == directory or string.sub(path, 1, #directory + 1) == directory .. "/"
end

local function is_below_any(directories, path)
  for _, taken in ipairs(directories) do
    if is_at_or_below(taken, path) then return true end
  end
  return false
end

local function is_package_of_its_own(context, path)
  return not nested.boundary_of(daukle.read(within(context.dir, path)))
end

local function is_candidate(context, path, is_member)
  if is_member == nil then return is_package_of_its_own(context, path) end
  return is_member[directory_of(path)] == true
end

--- Takes the nested packages of their own out of `facts.nested`, returning their directories for
--- core to migrate as instances of their own (core api 10, D-248). Only the outermost is taken,
--- with every file below it, since its own migration reads the rest. With `members`, a
--- workspace's member directories, only those are taken.
---
--- @implNote a workspace's other nested packages are never taken, whether `workspaces` or a
--- `pnpm-workspace.yaml` declares it: they still block as the nested-package row does.
local function take_instances(context, facts, members)
  local is_member = nil
  if members ~= nil then
    is_member = {}
    for _, directory in ipairs(members) do is_member[directory] = true end
  end
  local instances, relative = {}, {}
  for _, path in ipairs(facts.nested) do
    local directory = directory_of(path)
    if not is_below_any(relative, directory) and nested.directory_problem(directory) == nil
       and is_candidate(context, path, is_member) then
      relative[#relative + 1] = directory
      instances[#instances + 1] = within(context.dir, directory)
    end
  end
  local kept = {}
  for _, path in ipairs(facts.nested) do
    if not is_below_any(relative, path) then kept[#kept + 1] = path end
  end
  facts.nested = kept
  return instances
end

local function declares_workspaces(context, files)
  if files.exists["pnpm-workspace.yaml"] then return true end
  local text = daukle.read(within(context.dir, "package.json"))
  if type(text) == "string" and string.sub(text, 1, 3) == "\239\187\191" then text = string.sub(text, 4) end
  if string.match(text or "", "^%s*{") == nil then return false end
  return daukle.json_parse(text).workspaces ~= nil
end

local WORKSPACE_FIELD = '"workspaces"'

--- The pnpm workspace a project that installs with pnpm declares, or nil when it declares none:
--- its `packages` globs, its catalogs, and a blocker for each key or line it cannot carry.
local function pnpm_workspace_of(context, files, config)
  if not files.exists[pnpm_workspace.NAME] or not is_pnpm_project(files, config) then return nil end
  local where = within(context.dir, pnpm_workspace.NAME)
  local workspace, problem = pnpm_workspace.parse(daukle.read(where))
  local surface = "NPM-SURFACE.md: " .. package_fields.ROWS.workspaces
  if workspace == nil then
    return { packages = {}, blockers = { { construct = pnpm_workspace.NAME, where = where, why = problem,
                                           surface = surface } } }
  end
  workspace.blockers = {}
  for _, key in ipairs(workspace.unknown) do
    workspace.blockers[#workspace.blockers + 1] = { construct = key, where = where, surface = surface,
                                                    why = "is a workspace setting this toolchain does not carry over" }
  end
  for _, pattern in ipairs(pnpm_workspace.brace_globs(workspace)) do
    workspace.blockers[#workspace.blockers + 1] = { construct = pattern, where = where, surface = surface,
                                                    why = "is a packages glob with a brace set, which pnpm expands"
                                                          .. " and this toolchain does not, so its members are unknown" }
  end
  return workspace
end

--- A blocker for each member whose directory cannot be an instance of its own, its package.json
--- taken out of `facts.nested` so that it is not also the nested-package blocker.
local function unplaceable_member_blockers(context, facts, members)
  local refused, blockers = {}, {}
  for _, directory in ipairs(members) do
    local problem = nested.directory_problem(directory)
    if problem ~= nil then
      refused[directory .. "/package.json"] = true
      blockers[#blockers + 1] = { construct = directory, where = within(context.dir, directory .. "/package.json"),
                                  why = "is a workspace member whose directory " .. problem,
                                  surface = "NPM-SURFACE.md: " .. package_fields.ROWS.workspaces }
    end
  end
  local kept = {}
  for _, path in ipairs(facts.nested) do
    if not refused[path] then kept[#kept + 1] = path end
  end
  facts.nested = kept
  return blockers
end

--- The translation's blockers without the one the `"workspaces"` field raises: beside a
--- `pnpm-workspace.yaml`, pnpm ignores the field, so the migration owns and drops it.
local function without_workspaces_field(blockers)
  local kept = {}
  for _, refused in ipairs(blockers) do
    if refused.construct ~= WORKSPACE_FIELD then kept[#kept + 1] = refused end
  end
  return kept
end

--- The instance core names for the package in `dir`: `node` at the project root, else
--- `node-<dir>` with each `/` as `-`.
local function instance_of(dir)
  if dir == nil then return "node" end
  return "node-" .. (string.gsub(dir, "/", "-"))
end

--- The root's `workspace` key: each member's directory below the root mapped to the instance core
--- migrates it as, so the root's install runs the instances daukle.toml names.
local function adopt_workspace(context, translation, workspace, members)
  translation.blockers = without_workspaces_field(translation.blockers)
  for _, refused in ipairs(workspace.blockers) do translation.blockers[#translation.blockers + 1] = refused end
  local instances = {}
  for _, member in ipairs(members) do instances[member] = instance_of(within(context.dir, member)) end
  translation.config[pnpm_workspace.KEY] = { members = instances, catalog = workspace.catalog,
                                             catalogs = workspace.catalogs }
end

local function run_package(context, files, translation, workspace, members)
  local where = within(context.dir, "package.json")
  local boundaries, boundary_files = take_boundaries(context, files)
  translation.config[nested.KEY] = boundaries
  files.installs_with_pnpm = is_pnpm_project(files, translation.config)
  if workspace ~= nil then adopt_workspace(context, translation, workspace, members) end
  for _, refused in ipairs(pnpm_blockers(context, files, translation.config, where)) do
    translation.blockers[#translation.blockers + 1] = refused
  end
  if #translation.blockers > 0 then
    local _, version_blockers = narrowed_by_version_files(context, files, translation.candidates)
    for _, refused in ipairs(version_blockers) do translation.blockers[#translation.blockers + 1] = refused end
    return result(context, translation.config, file_blockers(context, files, translation.blockers), { where })
  end
  local rc = npmrc_of(context, files)
  translation.config.npmConfig, translation.config.npmrc = rc.config, rc.where
  local narrowed, version_blockers = narrowed_by_version_files(context, files, translation.candidates)
  if #version_blockers > 0 then
    return result(context, translation.config, file_blockers(context, files, version_blockers), { where })
  end
  translation.candidates = narrowed
  translation.config.version = narrowed[1]
  if files.exists["package-lock.json"] then
    local lock_where = within(context.dir, "package-lock.json")
    local version, refusal = accepting_version(context, translation.candidates, where, lock_where,
                                               npmrc.env(rc.config))
    if version == nil then
      return result(context, translation.config, file_blockers(context, files, {
        { construct = "package-lock.json", where = lock_where,
          why = "is refused by the npm of every pinned node that satisfies engines, newest first; "
                .. refusal, surface = "NPM-SURFACE.md: " .. LOCKFILE_ROW } }), { where })
    end
    translation.config.version = version
  end
  local is_member = translation.root ~= nil
  local facts, unresolved = probe(context, translation.config, npmrc.env(rc.config), is_member)
  local lock_text = (unresolved == nil and not is_member) and lock_of(context, files) or nil
  if files.installs_with_pnpm then lock_text = daukle.read(within(context.dir, PNPM_LOCK)) end
  local blockers
  if unresolved ~= nil then
    blockers = { { construct = "package.json", where = where,
                   why = "npm install could not resolve the declared dependencies: " .. unresolved,
                   surface = "NPM-SURFACE.md: " .. UNRESOLVED_ROW } }
  elseif is_member and next(translation.commands) ~= nil and not is_workspace_installed(translation.root) then
    blockers = { { construct = "scripts", where = where,
                   why = "run commands of the workspace's packages, and the workspace root "
                         .. within(translation.root.dir, "package.json") .. " did not install it, so"
                         .. " which package provides each command cannot be resolved",
                   surface = "NPM-SURFACE.md: " .. package_fields.ROWS.workspaces } }
  else
    blockers = translate.resolve_commands(translation.config, facts.bins, where)
    if #blockers == 0 then
      blockers = unpublishable_scripts(translation.config, translation.original_scripts, where)
    end
  end
  file_blockers(context, files, blockers)
  for _, entry in ipairs(ROOT_ENTRIES) do
    if facts.reincludedBy[entry.fact] ~= nil then
      blockers[#blockers + 1] = { construct = ".gitignore", where = within(context.dir, ".gitignore"),
                                  why = "may not ignore " .. entry.line .. ", which node:install places at"
                                        .. " the package root " .. entry.placed .. " "
                                        .. derived(context, entry.name) .. ": "
                                        .. root_entry_remedy(entry, facts.reincludedBy[entry.fact]),
                                  surface = "NPM-SURFACE.md: " .. ROOT_ENTRIES_ROW }
    end
  end
  for _, refused in ipairs(rc.blockers) do blockers[#blockers + 1] = refused end
  if has_any(rc.config) and not has_dependencies(translation.config) then
    blockers[#blockers + 1] = { construct = npmrc.NAME, where = rc.where,
                                why = "configures npm, and this package declares no dependencies for npm to"
                                      .. " resolve or install, so its keys would have nowhere to go",
                                surface = "NPM-SURFACE.md: 4. Install, lockfile and registry configuration: a project `.npmrc`" }
  end
  if translation.config.overrides ~= nil and not has_dependencies(translation.config) then
    blockers[#blockers + 1] = { construct = '"overrides"', where = where,
                                why = "overrides packages, and this package declares no dependencies for npm to"
                                      .. " resolve, so the overrides would have nowhere to go",
                                surface = "NPM-SURFACE.md: " .. translate.SURFACE.overrides }
  end
  local owned = { where }
  for _, path in ipairs(boundary_files) do owned[#owned + 1] = path end
  if files.exists["package-lock.json"] then owned[#owned + 1] = within(context.dir, "package-lock.json") end
  if files.installs_with_pnpm then owned[#owned + 1] = within(context.dir, PNPM_LOCK) end
  if workspace ~= nil then owned[#owned + 1] = within(context.dir, pnpm_workspace.NAME) end
  if files.exists["node_modules"] then owned[#owned + 1] = within(context.dir, "node_modules") end
  if files.exists[npmrc.NAME] then owned[#owned + 1] = rc.where end
  for _, name in ipairs(VERSION_FILES) do
    if files.exists[name] then owned[#owned + 1] = within(context.dir, name) end
  end
  return result(context, translation.config, blockers, owned, lock_text)
end

--- Every step of a translated script, an attempt's own steps included.
local function each_step(value, visit)
  if value[1] ~= nil then
    for _, step in ipairs(value) do each_step(step, visit) end
  elseif value.attempt ~= nil then
    each_step(value.attempt, visit)
    each_step(value.otherwise, visit)
  else
    visit(value)
  end
end

local NESTED_SCRIPT_ROW = "5. Scripts: `npm <script> --prefix <dir>`, a nested package's script"

--- A blocker for each `--prefix` step whose directory is not a nested package handed back as an
--- instance, or whose package declares no such script: the step runs that instance's task (D-255).
local function nested_script_blockers(context, config, instances, where)
  local handed_back = {}
  for _, directory in ipairs(instances) do handed_back[directory] = true end
  local blockers = {}
  for name, value in pairs(config.scripts or {}) do
    each_step(value, function(step)
      if step.package == nil then return end
      local directory = within(context.dir, step.package)
      local why
      if not handed_back[directory] then
        why = string.format('runs a script in "%s", which is not a package of its own this migration'
                            .. ' hands back', step.package)
      else
        local declared = daukle.json_parse(daukle.read(directory .. "/package.json")).scripts
        if type(declared) ~= "table" or declared[step.script] == nil then
          why = string.format('runs "%s" in "%s", whose package.json declares no such script', step.script,
                              step.package)
        end
      end
      if why ~= nil then
        blockers[#blockers + 1] = { construct = 'scripts."' .. name .. '"', where = where, why = why,
                                    surface = "NPM-SURFACE.md: " .. NESTED_SCRIPT_ROW }
      end
    end)
  end
  return blockers
end

--- The names in a directory of the project, `dir` nil for its root, as a set.
local function names_in(dir)
  local found = {}
  for _, entry in ipairs(daukle.list(dir or ".") or {}) do found[entry.name] = true end
  return found
end

local function parent_of(dir)
  return string.match(dir, "^(.+)/[^/]+$")
end

local function relative_to(dir, path)
  if dir == nil then return path end
  if path == dir then return "" end
  return string.sub(path, #dir + 2)
end

local function installs_with_pnpm_in(dir, exists)
  if not exists["package.json"] then return false end
  local where = within(dir, "package.json")
  return is_pnpm_project({ exists = exists }, translate.package(daukle.read(where), where).config)
end

local function root_of_member(context, dir, exists)
  local workspace = pnpm_workspace.parse(daukle.read(within(dir, pnpm_workspace.NAME)))
  if workspace == nil or not installs_with_pnpm_in(dir, exists) then return nil end
  local relative = relative_to(dir, context.dir)
  if #pnpm_workspace.members(workspace, { relative }) == 0 then return nil end
  return { dir = dir, instance = instance_of(dir), workspace = workspace }
end

--- The pnpm workspace root this package is a member of, `{ dir, instance, workspace }`, or nil.
---
--- @implNote the nearest `pnpm-workspace.yaml` above the package decides, as pnpm's own lookup
--- does: a package its globs do not match is in no workspace, even below a farther one that would.
local function workspace_root_of(context)
  if context.dir == nil then return nil end
  local dir = context.dir
  repeat
    dir = parent_of(dir)
    local exists = names_in(dir)
    if exists[pnpm_workspace.NAME] then return root_of_member(context, dir, exists) end
  until dir == nil
  return nil
end

--- The project-relative directory a `file:` range names from `dir`, "" for the project root, or
--- nil when it is absolute or climbs out of the project.
local function directory_named(dir, range)
  local target = string.sub(range, #"file:" + 1)
  if string.find(target, "\\", 1, true) or string.match(target, "^/") or string.match(target, "^%a:") then
    return nil
  end
  local segments = {}
  for segment in string.gmatch(dir or "", "[^/]+") do segments[#segments + 1] = segment end
  for segment in string.gmatch(target, "[^/]+") do
    if segment == ".." then
      if #segments == 0 then return nil end
      segments[#segments] = nil
    elseif segment ~= "." then
      segments[#segments + 1] = segment
    end
  end
  return table.concat(segments, "/")
end

--- Whether a `file:` range names the workspace root or one of its members, which pnpm links.
local function is_inside_workspace(context, root, range)
  local target = directory_named(context.dir, range)
  if target == nil or (root.dir ~= nil and not is_at_or_below(root.dir, target)) then return false end
  local relative = relative_to(root.dir, target)
  if relative ~= "" and #pnpm_workspace.members(root.workspace, { relative }) == 0 then return false end
  return names_in(target ~= "" and target or nil)["package.json"] == true
end

--- The workspace's members below this member, relative to it.
local function members_below(context, root, files)
  local prefix = relative_to(root.dir, context.dir) .. "/"
  local candidates = {}
  for index, directory in ipairs(nested_directories(files)) do candidates[index] = prefix .. directory end
  local below = {}
  for index, member in ipairs(pnpm_workspace.members(root.workspace, candidates)) do
    below[index] = string.sub(member, #prefix + 1)
  end
  return below
end

local PNPM_ENTRY = "migrate-pnpm/node_modules/pnpm/bin/pnpm.cjs"

--- The release the project's `packageManager` names, installed into the derived `migrate-pnpm`.
---
--- @implNote pnpm comes from the registry through the provisioned npm, as corepack would fetch it:
--- the old side is the original tool's own run, which may reach the network as its `npm ci` does.
local function install_pnpm(context, root, pick, pnpm, env)
  daukle.write{ path = "migrate-pnpm/package.json",
                text = '{ "private": true, "dependencies": { "pnpm": "' .. pnpm .. '" } }\n' }
  daukle.exec(root:tool(pick.node), { root:path(pick.npm), "install", "--ignore-scripts", "--no-audit", "--no-fund" },
              { cwd = derived(context, "migrate-pnpm"), env = env })
end

local REMOVE_WORKSPACE_STATE = 'const fs = require("node:fs");'
                               .. ' fs.rmSync("node_modules/.pnpm-workspace-state-v1.json", { force: true });'
                               .. ' try { fs.rmdirSync("node_modules"); } catch {}'

--- The original workspace installed once, with the project's own pnpm and its lockfile, in the
--- project's own tree: each project's modules land in its `WORKSPACE_MODULES_DIR`, and the virtual
--- store and the store in the root's derived `migrate-workspace`, so nothing is written outside a
--- `build/daukle` directory.
---
--- @return string|nil why pnpm refused the install, its first `ERR_PNPM_` line, or nil once it
--- installed; any other failure, a network one among them, raises
---
--- @implNote pnpm 10 writes `node_modules/.pnpm-workspace-state-v1.json` at the workspace root
--- whatever `--modules-dir` says, so a `node_modules` the project did not have is removed again.
local function install_old_workspace(context, root, pick, pnpm, env)
  local had_modules = names_in(context.dir)["node_modules"] == true
  local climb = paths.climb_from(context.dir)
  install_pnpm(context, root, pick, pnpm, env)
  local install = daukle.exec(root:tool(pick.node), {
    climb .. derived(context, PNPM_ENTRY), "install", "--frozen-lockfile", "--ignore-scripts",
    "--config.confirmModulesPurge=false", "--modules-dir", WORKSPACE_MODULES_DIR,
    "--virtual-store-dir", climb .. derived(context, "migrate-workspace/pnpm-virtual-store"),
    "--store-dir", climb .. derived(context, "migrate-workspace/pnpm-store"),
  }, { cwd = context.dir or ".", env = env, capture = true, check = false })
  if not had_modules then
    daukle.exec(root:tool(pick.node), { "-e", REMOVE_WORKSPACE_STATE }, { cwd = context.dir or "." })
  end
  if install.code == 0 then return nil end
  local output = (install.stdout or "") .. "\n" .. (install.stderr or "")
  local refusal = string.match(output, "(ERR_PNPM_[^\r\n]+)")
  if refusal == nil then
    error("pnpm install of the workspace failed with code " .. install.code .. ": "
          .. (string.match(output, "([^\r\n]+)[\r\n%s]*$") or ""), 0)
  end
  return refusal
end

--- The translation of a package, a pnpm workspace member's when `root` is its workspace root.
local function translation_of(context, root)
  local where = within(context.dir, "package.json")
  local member = nil
  if root ~= nil then
    member = { keeps_file_range = function(range) return is_inside_workspace(context, root, range) end }
  end
  local translation = translate.package(daukle.read(where), where, member)
  if root ~= nil then
    translation.root = root
    translation.config[pnpm_workspace.KEY] = root.instance
    if translation.config.overrides ~= nil then
      translation.config.overrides = nil
      translation.blockers[#translation.blockers + 1] = {
        construct = '"overrides"', where = where, surface = "NPM-SURFACE.md: " .. translate.SURFACE.overrides,
        why = "overrides packages in a pnpm workspace member, and pnpm applies overrides only from the"
              .. " workspace root, so they would not apply" }
    end
  end
  return translation
end

--- The pnpm workspace a root declares, the members it matches, and its blockers; or, for a member
--- of a workspace, the members below it, which it hands back so that it never owns their files.
local function workspace_and_members(context, files, translation)
  if translation.root ~= nil then
    return nil, members_below(context, translation.root, files), translation.blockers
  end
  local workspace = pnpm_workspace_of(context, files, translation.config)
  if workspace ~= nil then
    return workspace, pnpm_workspace.members(workspace, nested_directories(files)), workspace.blockers
  end
  if declares_workspaces(context, files) then return nil, {}, nil end
  return nil, nil, nil
end

local function run(context)
  local files = file_facts(context)
  local translation = translation_of(context, workspace_root_of(context))
  local workspace, members, member_refusals = workspace_and_members(context, files, translation)
  local instances = take_instances(context, files, members)
  if member_refusals ~= nil then
    for _, refused in ipairs(unplaceable_member_blockers(context, files, members)) do
      member_refusals[#member_refusals + 1] = refused
    end
  end
  local pnpm = translation.config.pnpm
  local answer = run_package(context, files, translation, workspace, members)
  local config = answer.manifest and answer.manifest.toolchains[context.instance]
  if config ~= nil then
    for _, refused in ipairs(nested_script_blockers(context, config, instances, within(context.dir, "package.json"))) do
      answer.blockers[#answer.blockers + 1] = refused
    end
  end
  if workspace ~= nil and #answer.blockers == 0 then
    local root, pick = provision(context, config.version)
    local refusal = install_old_workspace(context, root, pick, pnpm, npmrc.env(npmrc_of(context, files).config))
    if refusal ~= nil then
      answer.blockers[#answer.blockers + 1] = {
        construct = PNPM_LOCK, where = within(context.dir, PNPM_LOCK),
        why = "does not install the workspace with its own pnpm, so its members' commands cannot be"
              .. " resolved: " .. refusal,
        surface = "NPM-SURFACE.md: " .. LOCKFILE_ROW }
    end
  end
  answer.instances = instances
  return answer
end

--- The old project installed as pnpm installs it, with the release its `packageManager` names.
local function install_old_with_pnpm(context, root, pick, pnpm, env)
  install_pnpm(context, root, pick, pnpm, env)
  daukle.write{ path = "migrate-old/" .. PNPM_LOCK, text = daukle.read(within(context.dir, PNPM_LOCK)) }
  daukle.exec(root:tool(pick.node), { "../" .. PNPM_ENTRY, "install",
                                      "--frozen-lockfile", "--ignore-scripts", "--store-dir", "pnpm-store" },
              { cwd = derived(context, "migrate-old"), env = env })
end

local function install_old(context, files, translation, root, pick, env)
  daukle.write{ path = "migrate-old/package.json", text = daukle.read(within(context.dir, "package.json")) }
  if is_pnpm_project(files, translation.config) then
    install_old_with_pnpm(context, root, pick, translation.config.pnpm, env)
    return
  end
  local install = { root:path(pick.npm), "install", "--ignore-scripts" }
  if files.exists["package-lock.json"] then
    daukle.write{ path = "migrate-old/package-lock.json",
                  text = daukle.read(within(context.dir, "package-lock.json")) }
    install = { root:path(pick.npm), "ci", "--ignore-scripts" }
  end
  daukle.exec(root:tool(pick.node), install, { cwd = derived(context, "migrate-old"), env = env })
end

--- @implNote a workspace member's old side installs nothing of its own, and neither does its new
--- side: the one install of the original workspace is the root's.
local function build(context)
  local where = within(context.dir, "package.json")
  local translation = translation_of(context, workspace_root_of(context))
  local is_member = translation.root ~= nil
  local files = file_facts(context)
  local env = npmrc.env(npmrc_of(context, files).config)
  translation.candidates = narrowed_by_version_files(context, files, translation.candidates)
  translation.config.version = translation.candidates[1]
  if files.exists["package-lock.json"] then
    translation.config.version = accepting_version(context, translation.candidates, where,
                                                   within(context.dir, "package-lock.json"), env)
  end
  if not is_member then
    local _, unresolved = probe(context, translation.config, env)
    if unresolved ~= nil then error("npm install failed: " .. unresolved, 0) end
  end
  local root, pick = provision(context, translation.config.version)
  if not is_member then install_old(context, files, translation, root, pick, env) end
  daukle.write{ path = "migrate-old/" .. tree.SCRIPT_NAME, text = tree.SCRIPT }
  daukle.exec(root:tool(pick.node), { "./" .. tree.SCRIPT_NAME }, { cwd = derived(context, "migrate-old") })
  if translation.config[published.KEY] ~= nil then
    daukle.write{ path = "migrate-old/" .. pack.SCRIPT_NAME, text = pack.SCRIPT }
    local climb = paths.climb_from(context.dir)
    local mode = type(translation.original_scripts) == "table" and translation.original_scripts.prepare ~= nil
                 and "with-scripts" or "in-place"
    daukle.exec(root:tool(pick.node), { climb .. derived(context, "migrate-old/" .. pack.SCRIPT_NAME), mode,
                                        root:path(pick.npm), ".", climb .. derived(context, "migrate-old") },
                { cwd = context.dir or "." })
  end
end

return { run = run, build = build }
