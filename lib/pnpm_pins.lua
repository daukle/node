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

local function checked_pnpm(pnpm)
  if type(pnpm) ~= "table" then edited("has no pnpm") end
  for _, field in ipairs({ "version", "url", "sha256" }) do
    if type(pnpm[field]) ~= "string" then edited("names a pnpm with no " .. field) end
  end
  return pnpm
end

--- The pins set on `config`, or nil when there are none. Returns `{ text, pnpm, entries, packages,
--- package_ranges, dev_packages, dev_ranges, overrides }`.
local function read(config)
  local lock = config[KEY]
  if lock == nil then return nil end
  if type(lock) ~= "table" or type(lock.text) ~= "string" or type(lock.entries) ~= "table" then
    edited("holds no lockfile text and entries")
  end
  if lock.overrides ~= nil and type(lock.overrides) ~= "string" then edited("has overrides that are not JSON text") end
  local packages, package_ranges = checked_ranges(lock.dependencies, "dependencies")
  local dev_packages, dev_ranges = checked_ranges(lock.devDependencies, "devDependencies")
  return {
    text = lock.text,
    pnpm = checked_pnpm(lock.pnpm),
    entries = pins.checked_entries(lock.entries, KEY),
    packages = packages, package_ranges = package_ranges,
    dev_packages = dev_packages, dev_ranges = dev_ranges,
    overrides = lock.overrides,
  }
end

return { KEY = KEY, read = read }
