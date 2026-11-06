--- The key daukle/npm's pin file sets on this toolchain: npm's lockfile and each package's pin.
local KEY = "npmLock"

local NPM_OS = { linux = "linux", macos = "darwin", windows = "win32" }
local NPM_CPU = { x86_64 = "x64", aarch64 = "arm64" }

--- Whether npm's `os` or `cpu` list admits `value`: a `!name` entry excludes it, and a list
--- with any plain entry admits only those, which is npm's own rule.
local function admits(list, value)
  if list == nil then return true end
  local has_plain = false
  for index = 1, #list do
    local item = list[index]
    if item == "!" .. value then return false end
    if string.sub(item, 1, 1) ~= "!" then
      has_plain = true
      if item == value then return true end
    end
  end
  return not has_plain
end

--- The entries npm installs on this host.
---
--- @implNote `libc` is not filtered: daukle cannot tell glibc from musl, so on linux both
--- variants are fetched and npm picks, and off linux npm skips them unfetched as it does any
--- other entry this host cannot use.
local function for_host(entries, host)
  local os_name, cpu = NPM_OS[host.os], NPM_CPU[host.arch]
  local out = {}
  for index = 1, #entries do
    local entry = entries[index]
    local libc_only = entry.libc ~= nil and os_name ~= "linux"
    if admits(entry.os, os_name) and admits(entry.cpu, cpu) and not libc_only then
      out[#out + 1] = entry
    end
  end
  return out
end

local function checked_entry(entry, index)
  for _, field in ipairs({ "path", "url", "sha256", "as" }) do
    if type(entry[field]) ~= "string" then
      error(KEY .. ".entries[" .. index .. "] has no " .. field .. ": daukle/npm writes every"
            .. " entry with one, so daukle/npm/lock.lua was edited; run"
            .. ' "daukle npm:resolve --resolve" to write it again', 0)
    end
  end
  return entry
end

--- The `npm_config_*` environment daukle/npm recorded for the resolve, which install must match.
local function checked_env(env)
  if env == nil then return {} end
  if type(env) ~= "table" then error(KEY .. ".env must be a table: run \"daukle npm:resolve --resolve\"", 0) end
  for name, value in pairs(env) do
    if type(name) ~= "string" or string.sub(name, 1, 11) ~= "npm_config_" or type(value) ~= "string" then
      error(KEY .. ".env holds " .. tostring(name) .. ", which daukle/npm never writes, so"
            .. ' daukle/npm/lock.lua was edited; run "daukle npm:resolve --resolve" to write it again', 0)
    end
  end
  return env
end

local function sorted_names(map)
  local names = {}
  for name in pairs(map or {}) do names[#names + 1] = name end
  table.sort(names)
  return names
end

--- Whether no package of the lockfile is installed only to satisfy a peer, which npm marks
--- `peer: true`. Only then can an install ignore peer edges without pruning a package.
local function places_no_peer_only_package(packages)
  for _, entry in pairs(packages or {}) do
    if type(entry) == "table" and entry.peer == true then return false end
  end
  return true
end

--- The pins set on `config`, or nil when there are none. Returns `{ text, entries, packages,
--- package_ranges, dev_packages, dev_ranges, peer_free }`, the ranges read from the lockfile's
--- root entry, so the package.json npm checks the lockfile against is the one it was resolved from.
local function read(config)
  local lock = config[KEY]
  if lock == nil then return nil end
  if type(lock) ~= "table" or type(lock.text) ~= "string" or type(lock.entries) ~= "table" then
    error(KEY .. " is set by daukle/npm's daukle/npm/lock.lua and holds its text and entries;"
          .. ' run "daukle npm:resolve --resolve" to write it again', 0)
  end
  local entries = {}
  for index = 1, #lock.entries do entries[index] = checked_entry(lock.entries[index], index) end
  local packages = daukle.json_parse(lock.text).packages or {}
  local root = packages[""] or {}
  return {
    peer_free = places_no_peer_only_package(packages),
    text = lock.text,
    entries = entries,
    env = checked_env(lock.env),
    packages = sorted_names(root.dependencies),
    package_ranges = root.dependencies or {},
    dev_packages = sorted_names(root.devDependencies),
    dev_ranges = root.devDependencies or {},
  }
end

return { KEY = KEY, read = read, for_host = for_host }
