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

local PROBE_NAME = "__daukle_probe__.mjs"

--[[ @implNote the bins are read from the probe's own install so that the
     answer is npm's layout, not a guess from names. ]]
local PROBE = [==[
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));

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
  try { entries = readdirSync(join(here, "node_modules")); } catch { return names; }
  for (const entry of entries) {
    if (entry.startsWith(".")) continue;
    if (!entry.startsWith("@")) { names.push(entry); continue; }
    for (const scoped of readdirSync(join(here, "node_modules", entry))) names.push(entry + "/" + scoped);
  }
  return names.sort((left, right) => ("node_modules/" + left).localeCompare("node_modules/" + right, "en"));
}
const bins = {};
for (const name of topLevelPackages()) {
  let manifest;
  try { manifest = JSON.parse(readFileSync(join(here, "node_modules", name, "package.json"), "utf8")); }
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

--- The dependencies, handed to daukle/npm's translator rather than written here: npm's block
--- holds the ranges and its pin file the closure, so node's own block carries neither.
local function dependencies_of(config, lock_text)
  local packages, dev_packages, npm_config = config.packages, config.devPackages, config.npmConfig
  local npmrc_where, overrides = config.npmrc, config.overrides
  config.packages, config.devPackages, config.npmConfig, config.npmrc, config.overrides = nil, nil, nil, nil, nil
  if lock_text == nil or not (has_any(packages) or has_any(dev_packages)) then return {} end
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

--[[ @implNote the probe script still runs after a failed install, because the
     ignore facts need no node_modules and the report should carry them beside
     the install failure. ]]
local function probe(context, config, env)
  local root, pick = provision(context, config.version)
  daukle.write{ path = "migrate-probe/package.json", text = '{' .. PROBE_IDENTITY
                .. ', "private": true, "dependencies": ' .. json_object(config.packages)
                .. ', "devDependencies": ' .. json_object(config.devPackages)
                .. (config.overrides == nil and "" or (', "overrides": ' .. config.overrides)) .. '}\n' }
  daukle.write{ path = "migrate-probe/" .. PROBE_NAME, text = PROBE }
  local install = daukle.exec(root:tool(pick.node), { root:path(pick.npm), "install",
                                                      "--ignore-scripts", "--include=dev" },
                              { cwd = derived(context, "migrate-probe"), capture = true, env = env,
                                check = false })
  local unresolved = nil
  if install.code ~= 0 then
    local failure = npm_errors.of_install(install.stderr, install.code)
    if not failure.resolution then error("npm install failed: " .. failure.message, 0) end
    unresolved = failure.message
  end
  local answer = daukle.exec(root:tool(pick.node),
                             { paths.climb_from(context.dir) .. derived(context, "migrate-probe/" .. PROBE_NAME),
                               paths.climb_from(context.dir) },
                             { cwd = context.dir or ".", capture = true })
  return daukle.json_parse(answer.stdout), unresolved
end

local NPM_CONFIGURATION = "configures npm in a way this toolchain does not carry over"
local VERSION_FILES = { ".nvmrc", ".node-version" }
local VERSION_FILE_ROW = "1. The runtime: a node version file (`.nvmrc`, `.node-version`)"

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

--- The candidates narrowed by each node version file, read with nvm's meaning: a partial version
--- is the newest matching release and an exact one is exact; an alias is a blocker (D-242).
local function narrowed_by_version_files(context, files, candidates)
  local blockers = {}
  for _, name in ipairs(VERSION_FILES) do
    if files.exists[name] then
      local where = within(context.dir, name)
      local text = first_line(daukle.read(where))
      local version = text and string.match(text, "^[vV]?(%d+[%.%d]*)$")
      if version == nil or string.match(version, "^%d+%.?%d*%.?%d*$") == nil then
        blockers[#blockers + 1] = { construct = name, where = where,
                                    why = string.format('names "%s", which is an alias a version manager'
                                          .. ' looks up rather than a version', tostring(text)),
                                    surface = "NPM-SURFACE.md: " .. VERSION_FILE_ROW }
      else
        local allowed = engines.satisfying(version, nil) or {}
        local kept = {}
        for _, candidate in ipairs(candidates) do
          if contains(allowed, candidate) then kept[#kept + 1] = candidate end
        end
        if #kept == 0 then
          blockers[#blockers + 1] = { construct = name, where = where,
                                      why = string.format('names node %s, and no pinned node satisfies it'
                                            .. ' together with engines: this plugin pins %s', text,
                                            pinned_versions()),
                                      surface = "NPM-SURFACE.md: " .. VERSION_FILE_ROW }
        end
        candidates = kept
      end
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

local function file_blockers(context, facts, blockers)
  for _, refused in ipairs(REFUSED_FILES) do
    if facts.exists[refused.name] then
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
                  and nested.boundary_of(daukle.read(within(context.dir, path)), package_fields.METADATA)
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

local function run(context)
  local where = within(context.dir, "package.json")
  local files = file_facts(context)
  local boundaries, boundary_files = take_boundaries(context, files)
  local translation = translate.package(daukle.read(where), where)
  translation.config[nested.KEY] = boundaries
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
  local facts, unresolved = probe(context, translation.config, npmrc.env(rc.config))
  local lock_text = unresolved == nil and lock_of(context, files) or nil
  local blockers
  if unresolved ~= nil then
    blockers = { { construct = "package.json", where = where,
                   why = "npm install could not resolve the declared dependencies: " .. unresolved,
                   surface = "NPM-SURFACE.md: " .. UNRESOLVED_ROW } }
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
  if files.exists["node_modules"] then owned[#owned + 1] = within(context.dir, "node_modules") end
  if files.exists[npmrc.NAME] then owned[#owned + 1] = rc.where end
  for _, name in ipairs(VERSION_FILES) do
    if files.exists[name] then owned[#owned + 1] = within(context.dir, name) end
  end
  return result(context, translation.config, blockers, owned, lock_text)
end

local function build(context)
  local where = within(context.dir, "package.json")
  local translation = translate.package(daukle.read(where), where)
  local files = file_facts(context)
  local env = npmrc.env(npmrc_of(context, files).config)
  translation.candidates = narrowed_by_version_files(context, files, translation.candidates)
  translation.config.version = translation.candidates[1]
  if files.exists["package-lock.json"] then
    translation.config.version = accepting_version(context, translation.candidates, where,
                                                   within(context.dir, "package-lock.json"), env)
  end
  local _, unresolved = probe(context, translation.config, env)
  if unresolved ~= nil then error("npm install failed: " .. unresolved, 0) end
  local root, pick = provision(context, translation.config.version)
  daukle.write{ path = "migrate-old/package.json", text = daukle.read(where) }
  local install = { root:path(pick.npm), "install", "--ignore-scripts" }
  if files.exists["package-lock.json"] then
    daukle.write{ path = "migrate-old/package-lock.json",
                  text = daukle.read(within(context.dir, "package-lock.json")) }
    install = { root:path(pick.npm), "ci", "--ignore-scripts" }
  end
  daukle.exec(root:tool(pick.node), install, { cwd = derived(context, "migrate-old"), env = env })
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
