-- The floor is measured rather than read off when module.registerHooks was
-- added: v22.14.0 does not carry it and v23.4.0 does not either, so the 23 line
-- has its own floor. AUTHORING.md holds the ten-version table.
local FLOOR = { 22, 15, 0 }

-- Newest first, which is the order a constraint is matched in. npm is not
-- independently choosable: it is whatever the release bundles, and it is
-- recorded so a caller can report what it is about to run.
local RELEASES = {
  { version = "26.3.1",  npm = "11.16.0" },
  { version = "24.21.0", npm = "11.19.0" },
  { version = "22.15.0", npm = "10.9.2" },
}

-- daukle names the host; nodejs.org names the file.
local ASSET_OS = { linux = "linux", macos = "darwin", windows = "win" }
local ASSET_ARCH = { x86_64 = "x64", aarch64 = "arm64" }
local ASSET_EXT = { linux = "tar.gz", macos = "tar.gz", windows = "zip" }

-- Transcribed from the SHASUMS256.txt nodejs.org publishes beside each release.
-- Never computed from a file on disk: a digest taken from a working tree is a
-- digest of whatever the checkout did to the bytes.
local DIGESTS = {
  ["26.3.1"] = {
    ["linux/x86_64"]    = "e892cd615e637edebcf22f9653d80fba63167ad6754d20881fd52cc37be81441",
    ["linux/aarch64"]   = "2f0829b201e9db20996ae15bce62138df1e3d317775b005778b05cf7b19714f1",
    ["macos/x86_64"]    = "3ec9e5a28c641c088f3d04ad38721bfdedb2f8aa8c031979fa93df08b5a92e58",
    ["macos/aarch64"]   = "3f624ab0d774553c0d28b968e141d8c676a35a2811fb0b7b356ba9cbdce15f74",
    ["windows/x86_64"]  = "45001b289ebffe7b22260898f3750059183d8246042b88e8ffa4337e65e6763e",
    ["windows/aarch64"] = "021eb7de1d5257b24765f292dfcb469ff1528c29d88f48c875befb28114fb0fb",
  },
  ["24.21.0"] = {
    ["linux/x86_64"]    = "6e1db87ef58b8819e5d5402eff1536491b18edd8eb7bee5ef7897876e88dc5ff",
    ["linux/aarch64"]   = "724282c3b43aec998aa9527380465b45d229e021b58035f5f4f63095eabfe5d5",
    ["macos/x86_64"]    = "1462cb3b3046b815cf8ea436d3da450ec1a9f11dac7e5a46b0ada5305d7e8097",
    ["macos/aarch64"]   = "bed7eea5325e1108f32ce5228ddd6a5f0f08a499ee42aa7442aea583702f6057",
    ["windows/x86_64"]  = "158f7685b44de51f6c0df1d153526cbcd3e1bc739a8dfc607721cef75de9e541",
    ["windows/aarch64"] = "8779b1bde1d39f8d420e3b57aa657b39891af434d3de44a919044cec06785921",
  },
  ["22.15.0"] = {
    ["linux/x86_64"]    = "29d1c60c5b64ccdb0bc4e5495135e68e08a872e0ae91f45d9ec34fc135a17981",
    ["linux/aarch64"]   = "c3582722db988ed1eaefd590b877b86aaace65f68746726c1f8c79d26e5cc7de",
    ["macos/x86_64"]    = "f7f42bee60d602783d3a842f0a02a2ecd9cb9d7f6f3088686c79295b0222facf",
    ["macos/aarch64"]   = "92eb58f54d172ed9dee320b8450f1390db629d4262c936d5c074b25a110fed02",
    ["windows/x86_64"]  = "06067d4f0d463f90ed803d5eca5b039a05dec5d70fc7b7cc254803a59bd0e27c",
    ["windows/aarch64"] = "737cd7046d96575c2d6cd36e0355afba54b79296b0f403ef4b3b1b5852b10ab6",
  },
}

local function parse(text, what)
  local major, minor, patch = string.match(text, "^(%d+)%.(%d+)%.(%d+)$")
  if major == nil then major, minor = string.match(text, "^(%d+)%.(%d+)$") end
  if major == nil then major = string.match(text, "^(%d+)$") end
  if major == nil then
    error(string.format('%s "%s" is not a node version: write it as 22.15.0', what, text), 0)
  end
  return { tonumber(major), tonumber(minor or 0), tonumber(patch or 0) }
end

local function compare(left, right)
  for index = 1, 3 do
    if left[index] ~= right[index] then return left[index] < right[index] and -1 or 1 end
  end
  return 0
end

local function text_of(version)
  return string.format("%d.%d.%d", version[1], version[2], version[3])
end

local BELOW_FLOOR =
  'node %s is below %s, which is the lowest node whose module.registerHooks resolves'
  .. ' a bare specifier for both module systems: this toolchain resolves dependencies'
  .. ' through that hook and has nothing to fall back on'

--[[ @implNote the lower bound is refused rather than the resolved version,
     because a constraint is a statement about what the project tolerates. A
     project declaring ">=20" would resolve to a pinned release that happens to
     work and would still be claiming it runs on a node where the resolver
     cannot exist. ]]
local function lower_bound(constraint)
  if type(constraint) ~= "string" then
    error('a node toolchain version must be a string such as "22.15.0" or ">=22.15.0", not a '
          .. type(constraint), 0)
  end
  local bound = string.match(constraint, "^>=%s*(.+)$")
  if bound ~= nil then return parse(bound, "the lower bound of"), false end
  return parse(constraint, "the version"), true
end

local function resolve(constraint)
  local wanted, exact = lower_bound(constraint)
  if compare(wanted, FLOOR) < 0 then
    error(string.format(BELOW_FLOOR, text_of(wanted), text_of(FLOOR)), 0)
  end
  for index = 1, #RELEASES do
    local candidate = parse(RELEASES[index].version, "the pinned version")
    local order = compare(candidate, wanted)
    if (exact and order == 0) or (not exact and order >= 0) then return RELEASES[index] end
  end
  local pinned = RELEASES[1].version
  for index = 2, #RELEASES do pinned = pinned .. ", " .. RELEASES[index].version end
  error(string.format('no pinned node satisfies "%s": this plugin pins %s and does not'
                      .. ' fetch a version it has no digest for', constraint, pinned), 0)
end

local function for_host(request)
  local release = resolve(request.version)
  local asset_os = ASSET_OS[request.os]
  local asset_arch = ASSET_ARCH[request.arch]
  local digests = DIGESTS[release.version]
  local key = tostring(request.os) .. "/" .. tostring(request.arch)
  if asset_os == nil or asset_arch == nil or digests[key] == nil then
    error(string.format('no pinned node %s for this host (%s %s)',
                        release.version, tostring(request.os), tostring(request.arch)), 0)
  end

  -- The unpacker strips no leading component, so every member sits under the
  -- archive's own top-level directory and a caller composes one string.
  local prefix = string.format("node-v%s-%s-%s", release.version, asset_os, asset_arch)
  -- The Windows zip has no lib/ level and names the binary node.exe. One
  -- hardcoded path is wrong on one platform, which is why both live here.
  local node = request.os == "windows" and "node.exe" or "bin/node"
  local npm = request.os == "windows"
              and "node_modules/npm/bin/npm-cli.js"
              or "lib/node_modules/npm/bin/npm-cli.js"

  return {
    version = release.version,
    npm_version = release.npm,
    url = string.format("https://nodejs.org/dist/v%s/%s.%s",
                        release.version, prefix, ASSET_EXT[request.os]),
    sha256 = digests[key],
    prefix = prefix,
    node = prefix .. "/" .. node,
    npm = prefix .. "/" .. npm,
  }
end

return { for_host = for_host, floor = text_of(FLOOR) }
