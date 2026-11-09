--- The key daukle/pnpm's pin file sets on this toolchain: pnpm's lockfile, the pinned pnpm, the
--- ranges the closure was resolved from, and each package's pin (D-251).
local pins = daukle.require("lib/pins")

local KEY = "pnpmLock"

local AGAIN = ' run "daukle pnpm:resolve --resolve" to write it again'

local function edited(what)
  error(KEY .. " " .. what .. ": daukle/pnpm writes it, so daukle/pnpm/lock.lua was edited;" .. AGAIN, 0)
end

local function checked_ranges(ranges, field)
  if type(ranges) ~= "table" then edited("has no " .. field) end
  local names = {}
  for name, range in pairs(ranges) do
    if type(name) ~= "string" or type(range) ~= "string" then edited("holds a " .. field .. " entry that is not name to range") end
    names[#names + 1] = name
  end
  table.sort(names)
  return names, ranges
end

local function check_fields(table_of_fields, fields, label)
  for _, field in ipairs(fields) do
    if type(table_of_fields[field]) ~= "string" then edited("names a " .. label .. " with no " .. field) end
  end
end

--- A release's one tarball, or from pnpm 12 its `binaries`, a native binary per `os/arch`.
local function checked_pnpm(pnpm)
  if type(pnpm) ~= "table" then edited("has no pnpm") end
  if type(pnpm.binaries) ~= "table" then
    check_fields(pnpm, { "version", "url", "sha256" }, "pnpm")
    return pnpm
  end
  check_fields(pnpm, { "version" }, "pnpm")
  for _, binary in pairs(pnpm.binaries) do check_fields(binary, { "url", "sha256", "file" }, "pnpm binary") end
  return pnpm
end

--- The pins set on `config`, or nil when there are none. Returns `{ text, pnpm, entries, packages,
--- package_ranges, dev_packages, dev_ranges, peer_packages, peer_ranges, optional_packages, optional_ranges,
--- peer_meta, overrides }`.
---
--- @implNote a pin file written before `D-268` holds no peers or optionals, which means none.
local function read(config)
  local lock = config[KEY]
  if lock == nil then return nil end
  if type(lock) ~= "table" or type(lock.text) ~= "string" or type(lock.entries) ~= "table" then
    edited("holds no lockfile text and entries")
  end
  if lock.overrides ~= nil and type(lock.overrides) ~= "string" then edited("has overrides that are not JSON text") end
  local packages, package_ranges = checked_ranges(lock.dependencies, "dependencies")
  local dev_packages, dev_ranges = checked_ranges(lock.devDependencies, "devDependencies")
  local peer_packages, peer_ranges = checked_ranges(lock.peerDependencies or {}, "peerDependencies")
  local optional_packages, optional_ranges = checked_ranges(lock.optionalDependencies or {}, "optionalDependencies")
  return {
    text = lock.text,
    pnpm = checked_pnpm(lock.pnpm),
    entries = pins.checked_entries(lock.entries, KEY),
    packages = packages, package_ranges = package_ranges,
    dev_packages = dev_packages, dev_ranges = dev_ranges,
    peer_packages = peer_packages, peer_ranges = peer_ranges,
    optional_packages = optional_packages, optional_ranges = optional_ranges,
    peer_meta = lock.peerPackagesMeta,
    overrides = lock.overrides,
  }
end

return { KEY = KEY, read = read }
