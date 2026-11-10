local links = daukle.require("lib/links")
local pnpm_workspace = daukle.require("lib/pnpm_workspace")

--- The dependency ranges a packed workspace package publishes, as `pnpm pack` writes them: its
--- consumer has neither the workspace nor the catalog a `workspace:` or `catalog:` range names.
local workspace_ranges = {}

local WORKSPACE_PREFIX = "workspace:"

local RANGE_FIELDS = {
  { names = "packages", ranges = "package_ranges" },
  { names = "dev_packages", ranges = "dev_ranges" },
  { names = "peer_packages", ranges = "peer_ranges" },
  { names = "optional_packages", ranges = "optional_ranges" },
}

local function generated(instance, name)
  return daukle.read("build/daukle/" .. instance .. "/" .. name)
end

local function record_version(versions, instance)
  local manifest = daukle.json_parse(generated(instance, "package.json"))
  if manifest.name ~= nil then versions[manifest.name] = manifest.version end
end

--- Each workspace project's version by its name, read from the package.json each one generated.
local function versions_in(root_instance)
  local versions = {}
  record_version(versions, root_instance)
  local placement = daukle.json_parse(generated(root_instance, links.WORKSPACE_NAME))
  for instance in pairs(placement.members) do record_version(versions, instance) end
  return versions
end

local function version_range(specifier, version)
  if specifier == "*" then return version end
  if specifier == "^" or specifier == "~" then return specifier .. version end
  return specifier
end

--- @implNote `workspace:<alias>@<range>` installs the sibling named `alias` under another name,
--- which a registry spells `npm:<alias>@<version>`.
local function resolved_workspace_range(package_name, range, versions)
  local specifier = string.sub(range, #WORKSPACE_PREFIX + 1)
  local alias, aliased = string.match(specifier, "^(.+)@([^@]*)$")
  local sibling = alias or package_name
  local version = versions[sibling]
  if version == nil then
    error('node:pack: "' .. package_name .. '" is "' .. range .. '", and no project of this workspace is named "'
          .. sibling .. '" with a version to publish it at', 0)
  end
  local published = version_range(aliased or specifier, version)
  if alias ~= nil then return "npm:" .. alias .. "@" .. published end
  return published
end

local function resolved_range(package_name, range, workspace, versions)
  local lowered = string.lower(range)
  if string.sub(lowered, 1, #WORKSPACE_PREFIX) == WORKSPACE_PREFIX then
    return resolved_workspace_range(package_name, range, versions)
  end
  if string.sub(lowered, 1, 8) == "catalog:" then
    local from_catalog = pnpm_workspace.catalog_range(workspace, package_name, range)
    if from_catalog == nil then
      error('node:pack: "' .. package_name .. '" is "' .. range .. '", which no catalog of this workspace lists', 0)
    end
    return from_catalog
  end
  return range
end

--- Whether the package belongs to a workspace, and so can name a range only a workspace resolves.
function workspace_ranges.applies(spec)
  return spec.workspace ~= nil or spec.workspace_root ~= nil
end

--- The workspace root as a path from a member's derived directory, or nil for the root itself.
function workspace_ranges.root_of_member(context, spec)
  if spec.workspace_root == nil then return nil end
  local placement = daukle.json_parse(generated(spec.workspace_root, links.WORKSPACE_NAME))
  local below_root = "/" .. placement.members[context.toolchain.name]
  if string.sub(context.root, -#below_root) ~= below_root then
    error('node:pack: "' .. context.root .. '" does not end in its workspace directory "' .. below_root .. '"', 0)
  end
  return string.sub(context.root, 1, #context.root - #below_root)
end

local DROPPED_WHEN_PACKED = { prepare = true, prepack = true, postpack = true }

--- The scripts `pnpm pack` keeps: it drops these three and leaves `"scripts": {}` when nothing else
--- remains (measured on 8.9.2, 10.34.9 and 12.18.0). Its other dropped names are all blocked.
local function without_pack_lifecycle(scripts)
  local kept = {}
  for _, script in ipairs(scripts) do
    if not DROPPED_WHEN_PACKED[script.name] then kept[#kept + 1] = script end
  end
  return kept
end

--- A copy of `spec` whose ranges are the ones `pnpm pack` publishes.
function workspace_ranges.resolved(spec, own_instance)
  local root_instance = spec.workspace_root or own_instance
  local workspace = pnpm_workspace.parse(generated(root_instance, links.WORKSPACE_FILE_NAME))
  local versions = versions_in(root_instance)
  local copy = {}
  for key, value in pairs(spec) do copy[key] = value end
  for _, field in ipairs(RANGE_FIELDS) do
    local ranges = {}
    for _, name in ipairs(spec[field.names]) do
      ranges[name] = resolved_range(name, spec[field.ranges][name], workspace, versions)
    end
    copy[field.ranges] = ranges
  end
  copy.scripts = without_pack_lifecycle(spec.scripts)
  copy.keeps_empty_scripts = #spec.scripts > 0
  return copy
end

return workspace_ranges
