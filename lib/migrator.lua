local runtimes = daukle.require("lib/runtimes")
local translate = daukle.require("lib/translate")
local tree = daukle.require("lib/tree")
local paths = daukle.require("lib/paths")
local npm_errors = daukle.require("lib/npm_errors")

local PROBE_NAME = "__daukle_probe__.mjs"

--[[ @implNote the bins are read from the probe's own install so that the
     answer is npm's layout, not a guess from names. ]]
local PROBE = [==[
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));

const ignored = { node_modules: false, package_json: false };
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
        ignored[entry.fact] = false;
        reincludedBy[entry.fact] = { line, file: path };
      } else if (!negated && entry.forms(prefixFromIgnoreFile).includes(pattern)) {
        ignored[entry.fact] = true;
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
} catch {
  ignored.node_modules = false;
  ignored.package_json = false;
  delete reincludedBy.node_modules;
  delete reincludedBy.package_json;
}
const own = JSON.parse(readFileSync(join(here, "package.json"), "utf8"));
const bins = {};
for (const name of Object.keys({ ...own.dependencies, ...own.devDependencies })) {
  let manifest;
  try { manifest = JSON.parse(readFileSync(join(here, "node_modules", name, "package.json"), "utf8")); }
  catch { continue; }
  const map = typeof manifest.bin === "object" && manifest.bin !== null;
  const commands = typeof manifest.bin === "string"
    ? [name.replace(/^@[^/]+\//, "")]
    : Object.keys(map ? manifest.bin : {});
  for (const command of commands) (bins[command] ??= []).push({ name, map });
}
process.stdout.write(JSON.stringify({ bins, ignored, reincludedBy }));
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

local function proof_of(context)
  return {
    task = context.instance .. ":tree",
    compare = { {
      old = derived(context, "migrate-old/" .. tree.OUTPUT_NAME),
      new = derived(context, tree.OUTPUT_NAME),
      as = "bytes",
    } },
  }
end

local function result(context, config, blockers, owned)
  return {
    manifest = { toolchains = { [context.instance] = config } },
    foreign = {},
    blockers = blockers,
    owned = owned,
    proof = proof_of(context),
  }
end

local PROBE_IDENTITY ='"name": "daukle-migrate-probe", "version": "0.0.0"'

--[[ @implNote the probe script still runs after a failed install, because the
     ignore facts need no node_modules and the report should carry them beside
     the install failure. ]]
local function probe(context, config)
  local root, pick = provision(context, config.version)
  daukle.write{ path = "migrate-probe/package.json", text = '{' .. PROBE_IDENTITY
                .. ', "private": true, "dependencies": ' .. json_object(config.packages)
                .. ', "devDependencies": ' .. json_object(config.devPackages) .. '}\n' }
  daukle.write{ path = "migrate-probe/" .. PROBE_NAME, text = PROBE }
  local install = daukle.exec(root:tool(pick.node), { root:path(pick.npm), "install",
                                                      "--ignore-scripts", "--include=dev" },
                              { cwd = derived(context, "migrate-probe"), capture = true,
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
local VERSION_MANAGER = "names a node version for a version manager, which this toolchain never"
                        .. " reads beside the version it writes"

local NESTED_PACKAGE = "is a package.json below the package root, which node reads for the format"
                       .. " and resolution of the files under it, and which the toolchain's"
                       .. " declared type would override"
local NESTED_ROW = "2. Module resolution: a nested `package.json` below the package root"
local UNRESOLVED_ROW = "3. Dependencies: the declared dependencies do not resolve"

local FOREIGN_LOCKFILE = "pins this project's dependencies for another package manager, and the"
                         .. " migration would install with npm and drop those pins"
local FOREIGN_LOCKFILE_ROW = "4. Install, lockfile and registry configuration: another package"
                             .. " manager's lockfile (`yarn.lock`, `pnpm-lock.yaml`, `bun.lock`, `bun.lockb`)"

local ROOT_ENTRIES_ROW = "2. Module resolution: a tool that resolves `node_modules` or reads `package.json` itself"
local ROOT_ENTRIES = {
  { fact = "node_modules", line = "node_modules", name = "node_modules", placed = "as a link to" },
  { fact = "package_json", line = "/package.json", name = "package.json", placed = "as a copy of" },
}

local function root_entry_remedy(entry, reincluded)
  if reincluded == nil then return "add the line " .. entry.line end
  return "the negation " .. reincluded.line .. " in " .. reincluded.file .. " can re-include it:"
         .. " remove that negation, or repeat " .. entry.line .. " below it"
end

local REFUSED_FILES = {
  { name = "npm-shrinkwrap.json", why = NPM_CONFIGURATION,
    row = "4. Install, lockfile and registry configuration: a committed `package-lock.json` or `npm-shrinkwrap.json`" },
  { name = ".npmrc", why = NPM_CONFIGURATION,
    row = "4. Install, lockfile and registry configuration: a project `.npmrc`: scoped registries, `_authToken`, `${VAR}`" },
  { name = ".nvmrc", why = VERSION_MANAGER, row = "1. The runtime" },
  { name = ".node-version", why = VERSION_MANAGER, row = "1. The runtime" },
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

local function run(context)
  local where = within(context.dir, "package.json")
  local files = file_facts(context)
  local translation = translate.package(daukle.read(where), where)
  if #translation.blockers > 0 then
    return result(context, translation.config, file_blockers(context, files, translation.blockers), { where })
  end
  local facts, unresolved = probe(context, translation.config)
  local blockers
  if unresolved ~= nil then
    blockers = { { construct = "package.json", where = where,
                   why = "npm install could not resolve the declared dependencies: " .. unresolved,
                   surface = "NPM-SURFACE.md: " .. UNRESOLVED_ROW } }
  else
    blockers = translate.resolve_commands(translation.config, facts.bins, where)
  end
  file_blockers(context, files, blockers)
  for _, entry in ipairs(ROOT_ENTRIES) do
    if not facts.ignored[entry.fact] then
      blockers[#blockers + 1] = { construct = ".gitignore", where = within(context.dir, ".gitignore"),
                                  why = "does not ignore " .. entry.line .. ", which node:install places at"
                                        .. " the package root " .. entry.placed .. " "
                                        .. derived(context, entry.name) .. ": "
                                        .. root_entry_remedy(entry, facts.reincludedBy[entry.fact]),
                                  surface = "NPM-SURFACE.md: " .. ROOT_ENTRIES_ROW }
    end
  end
  local owned = { where }
  if files.exists["package-lock.json"] then owned[#owned + 1] = within(context.dir, "package-lock.json") end
  if files.exists["node_modules"] then owned[#owned + 1] = within(context.dir, "node_modules") end
  return result(context, translation.config, blockers, owned)
end

local function build(context)
  local where = within(context.dir, "package.json")
  local translation = translate.package(daukle.read(where), where)
  local _, unresolved = probe(context, translation.config)
  if unresolved ~= nil then error("npm install failed: " .. unresolved, 0) end
  local files = file_facts(context)
  local root, pick = provision(context, translation.config.version)
  daukle.write{ path = "migrate-old/package.json", text = daukle.read(where) }
  local install = { root:path(pick.npm), "install", "--ignore-scripts" }
  if files.exists["package-lock.json"] then
    daukle.write{ path = "migrate-old/package-lock.json",
                  text = daukle.read(within(context.dir, "package-lock.json")) }
    install = { root:path(pick.npm), "ci", "--ignore-scripts" }
  end
  daukle.exec(root:tool(pick.node), install, { cwd = derived(context, "migrate-old") })
  daukle.write{ path = "migrate-old/" .. tree.SCRIPT_NAME, text = tree.SCRIPT }
  daukle.exec(root:tool(pick.node), { "./" .. tree.SCRIPT_NAME }, { cwd = derived(context, "migrate-old") })
end

return { run = run, build = build }
