local runtimes = daukle.require("lib/runtimes")
local translate = daukle.require("lib/translate")
local tree = daukle.require("lib/tree")
local paths = daukle.require("lib/paths")

local PROBE_NAME = "__daukle_probe__.mjs"

--[[ @implNote existence is asked of node because daukle.read raises on a
     missing file and the sandbox has no pcall, and a missing owned path is a
     blocker in core. The bins are read from the probe's own install so that
     the answer is npm's layout, not a guess from names. ]]
local PROBE = [==[
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const exists = {};
for (const name of ["package-lock.json", "npm-shrinkwrap.json", "node_modules", ".npmrc", ".nvmrc", ".node-version"]) {
  exists[name] = existsSync(name);
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
process.stdout.write(JSON.stringify({ exists, bins }));
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

local function probe(context, config)
  local root, pick = provision(context, config.version)
  daukle.write{ path = "migrate-probe/package.json", text = '{"private": true, "dependencies": '
                .. json_object(config.packages) .. ', "devDependencies": '
                .. json_object(config.devPackages) .. '}\n' }
  daukle.write{ path = "migrate-probe/" .. PROBE_NAME, text = PROBE }
  daukle.exec(root:tool(pick.node), { root:path(pick.npm), "install", "--ignore-scripts",
                                      "--include=dev" },
              { cwd = derived(context, "migrate-probe") })
  local answer = daukle.exec(root:tool(pick.node),
                             { paths.climb_from(context.dir) .. derived(context, "migrate-probe/" .. PROBE_NAME) },
                             { cwd = context.dir or ".", capture = true })
  return daukle.json_parse(answer.stdout)
end

local NPM_CONFIGURATION = "configures npm in a way this toolchain does not carry over"
local VERSION_MANAGER = "names a node version for a version manager, which this toolchain never"
                        .. " reads beside the version it writes"

local REFUSED_FILES = {
  { name = "npm-shrinkwrap.json", why = NPM_CONFIGURATION,
    row = "4. Install, lockfile and registry configuration: a committed `package-lock.json` or `npm-shrinkwrap.json`" },
  { name = ".npmrc", why = NPM_CONFIGURATION,
    row = "4. Install, lockfile and registry configuration: a project `.npmrc`: scoped registries, `_authToken`, `${VAR}`" },
  { name = ".nvmrc", why = VERSION_MANAGER, row = "1. The runtime" },
  { name = ".node-version", why = VERSION_MANAGER, row = "1. The runtime" },
}

local function run(context)
  local where = within(context.dir, "package.json")
  local translation = translate.package(daukle.read(where), where)
  if #translation.blockers > 0 then
    return result(context, translation.config, translation.blockers, { where })
  end
  local facts = probe(context, translation.config)
  local blockers = translate.resolve_commands(translation.config, facts.bins, where)
  for _, refused in ipairs(REFUSED_FILES) do
    if facts.exists[refused.name] then
      blockers[#blockers + 1] = { construct = refused.name, where = within(context.dir, refused.name),
                                  why = refused.why, surface = "NPM-SURFACE.md: " .. refused.row }
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
  local facts = probe(context, translation.config)
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
