local runtimes = daukle.require("lib/runtimes")
local translate = daukle.require("lib/translate")
local tree = daukle.require("lib/tree")
local paths = daukle.require("lib/paths")
local npm_errors = daukle.require("lib/npm_errors")

local PROBE_NAME = "__daukle_probe__.mjs"

--[[ @implNote existence is asked of node because daukle.read raises on a
     missing file and the sandbox has no pcall, and a missing owned path is a
     blocker in core. The bins are read from the probe's own install so that
     the answer is npm's layout, not a guess from names. ]]
local PROBE = [==[
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const exists = {};
for (const name of ["package-lock.json", "npm-shrinkwrap.json", "node_modules", ".npmrc", ".nvmrc", ".node-version",
                    "yarn.lock", "pnpm-lock.yaml", "bun.lock", "bun.lockb"]) {
  exists[name] = existsSync(name);
}

const nested = [];
const unreadable = [];
function isSkipped(path, name) {
  return name === "node_modules" || name === ".git" || path === "build/daukle";
}
function findNested(directory) {
  let entries;
  try { entries = readdirSync(directory || ".", { withFileTypes: true }); }
  catch (error) { unreadable.push({ path: directory || ".", why: error.code || error.message }); return; }
  for (const entry of entries) {
    const path = directory ? directory + "/" + entry.name : entry.name;
    if (entry.isDirectory()) {
      if (isSkipped(path, entry.name)) continue;
      findNested(path);
    } else if (directory && entry.name === "package.json") {
      nested.push(path);
    }
  }
}
findNested("");
nested.sort();

const ignored = { node_modules: false, package_json: false };
/** @implNote no accepted form ends in a slash: git classifies a POSIX symlink as a file, so a directory-only pattern does not ignore the link node:install places (Git for Windows treats a junction as a directory, which hides this there). */
const ROOT_ENTRIES = [
  { fact: "node_modules", name: "node_modules",
    forms: (prefixFromIgnoreFile) => ["node_modules", "**/node_modules", "/" + prefixFromIgnoreFile + "node_modules"] },
  { fact: "package_json", name: "package.json",
    forms: (prefixFromIgnoreFile) => ["package.json", "**/package.json", "/" + prefixFromIgnoreFile + "package.json"] },
];
/** @implNote any negation that could reach the entry, by a wildcard or by naming it, clears the fact without being matched: a false "ignored" lets generated files be committed, a false "not ignored" costs the user one line. */
function mayUnignore(pattern, entry) {
  return /[*?[]/.test(pattern) || pattern.includes(entry.name);
}
function readIgnoreLines(path) {
  try { return readFileSync(path, "utf8").split("\n"); }
  catch (error) { if (error.code === "ENOENT") return []; throw error; }
}
/** @implNote only the end of a line is trimmed, because git keeps leading whitespace as part of the pattern. */
function applyIgnore(path, prefixFromIgnoreFile) {
  for (const raw of readIgnoreLines(path)) {
    const line = raw.trimEnd();
    if (line === "" || line.startsWith("#")) continue;
    const negated = line.startsWith("!");
    const pattern = negated ? line.slice(1) : line;
    for (const entry of ROOT_ENTRIES) {
      if (negated && mayUnignore(pattern, entry)) ignored[entry.fact] = false;
      else if (!negated && entry.forms(prefixFromIgnoreFile).includes(pattern)) ignored[entry.fact] = true;
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
process.stdout.write(JSON.stringify({ exists, bins, nested, unreadable, ignored }));
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
     existence and nested-package facts need no node_modules and are often the
     real reason the install failed (a yarn.lock or .npmrc it would have read). ]]
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
  { fact = "node_modules", line = "node_modules" },
  { fact = "package_json", line = "/package.json" },
}

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

local function run(context)
  local where = within(context.dir, "package.json")
  local translation = translate.package(daukle.read(where), where)
  if #translation.blockers > 0 then
    return result(context, translation.config, translation.blockers, { where })
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
  for _, entry in ipairs(ROOT_ENTRIES) do
    if not facts.ignored[entry.fact] then
      blockers[#blockers + 1] = { construct = ".gitignore", where = within(context.dir, ".gitignore"),
                                  why = "does not ignore " .. entry.line .. ", which node:install places at"
                                        .. " the package root as links into build/daukle/" .. context.instance
                                        .. ": add the line " .. entry.line,
                                  surface = "NPM-SURFACE.md: " .. ROOT_ENTRIES_ROW }
    end
  end
  local owned = { where }
  if facts.exists["package-lock.json"] then owned[#owned + 1] = within(context.dir, "package-lock.json") end
  if facts.exists["node_modules"] then owned[#owned + 1] = within(context.dir, "node_modules") end
  return result(context, translation.config, blockers, owned)
end

local function build(context)
  local where = within(context.dir, "package.json")
  local translation = translate.package(daukle.read(where), where)
  local facts, unresolved = probe(context, translation.config)
  if unresolved ~= nil then error("npm install failed: " .. unresolved, 0) end
  local root, pick = provision(context, translation.config.version)
  daukle.write{ path = "migrate-old/package.json", text = daukle.read(where) }
  local install = { root:path(pick.npm), "install", "--ignore-scripts" }
  if facts.exists["package-lock.json"] then
    daukle.write{ path = "migrate-old/package-lock.json",
                  text = daukle.read(within(context.dir, "package-lock.json")) }
    install = { root:path(pick.npm), "ci", "--ignore-scripts" }
  end
  daukle.exec(root:tool(pick.node), install, { cwd = derived(context, "migrate-old") })
  daukle.write{ path = "migrate-old/" .. tree.SCRIPT_NAME, text = tree.SCRIPT }
  daukle.exec(root:tool(pick.node), { "./" .. tree.SCRIPT_NAME }, { cwd = derived(context, "migrate-old") })
end

return { run = run, build = build }
