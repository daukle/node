--- A project's `.npmrc`, read as npm's `ini` package reads it, into the keys daukle/npm carries as
--- `npmConfig` (D-232). Which keys may be carried is daukle/npm's to decide; this reads the syntax.
local npmrc = {}

npmrc.NAME = ".npmrc"

local ROW = "4. Install, lockfile and registry configuration: a project `.npmrc`"

local function trimmed(text)
  return (string.match(text, "^%s*(.-)%s*$"))
end

--- @implNote an unquoted value ends at the first `;` or `#` no backslash escapes, as `ini` cuts it.
local function unquoted_value(text)
  local out, index = {}, 1
  while index <= #text do
    local character = string.sub(text, index, index)
    if character == "\\" and string.find(";#\\", string.sub(text, index + 1, index + 1), 1, true) then
      out[#out + 1] = string.sub(text, index + 1, index + 1)
      index = index + 2
    elseif character == ";" or character == "#" then
      break
    else
      out[#out + 1] = character
      index = index + 1
    end
  end
  return trimmed(table.concat(out))
end

local function value_of(text)
  local quote = string.sub(text, 1, 1)
  if (quote == '"' or quote == "'") and #text >= 2 and string.sub(text, -1) == quote then
    return string.sub(text, 2, -2)
  end
  return unquoted_value(text)
end

local function blocker(where, construct, why)
  return { construct = construct, where = where, why = why, surface = "NPM-SURFACE.md: " .. ROW }
end

--- The keys of an `.npmrc` text as `{ config = key -> value, blockers }`.
function npmrc.read(text, where)
  local config, blockers = {}, {}
  text = string.gsub(text, "^\239\187\191", "")
  for raw in string.gmatch(text .. "\n", "([^\n]*)\n") do
    local line = trimmed(string.gsub(raw, "\r$", ""))
    local first = string.sub(line, 1, 1)
    if line ~= "" and first ~= ";" and first ~= "#" then
      local key, rest = string.match(line, "^([^=]-)%s*=%s*(.*)$")
      if key == nil then key, rest = line, "true" end
      key = trimmed(key)
      if string.match(line, "^%[.*%]$") then
        blockers[#blockers + 1] = blocker(where, line, "is an ini section, which npm reads as a nested"
                                                       .. " object no npm config key takes")
      elseif string.sub(key, -2) == "[]" then
        blockers[#blockers + 1] = blocker(where, key, "is a list, which npm config passes as repeated"
                                                      .. " values and the environment cannot")
      else
        config[key] = value_of(rest)
      end
    end
  end
  return { config = config, blockers = blockers }
end

--- The environment npm reads the keys from, named as npm names its `npm_config_*` variables.
function npmrc.env(config)
  local env = {}
  for key, value in pairs(config or {}) do
    env["npm_config_" .. string.gsub(key, "%-", "_")] = value
  end
  return env
end

return npmrc
