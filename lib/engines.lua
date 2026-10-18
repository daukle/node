local runtimes = daukle.require("lib/runtimes")

local UNREADABLE = 'cannot read the engines.node range "%s": it is read as npm\'s semver ranges'
                   .. ' without prerelease tags'

local function partial(text)
  text = string.gsub(text, "^[vV=]", "")
  if text == "" or text == "*" or text == "x" or text == "X" then return {} end
  local pieces = {}
  for piece in string.gmatch(text, "[^%.]+") do pieces[#pieces + 1] = piece end
  if #pieces > 3 or select(2, string.gsub(text, "%.", "")) ~= #pieces - 1 then return nil end
  local out = {}
  for index = 1, #pieces do
    local piece = pieces[index]
    if piece == "x" or piece == "X" or piece == "*" then break end
    if string.match(piece, "^%d+$") == nil then return nil end
    out[index] = tonumber(piece)
  end
  return out
end

local function full(version)
  return { version[1] or 0, version[2] or 0, version[3] or 0 }
end

local function bumped(version)
  if #version == 1 then return { version[1] + 1, 0, 0 } end
  return { version[1], version[2] + 1, 0 }
end

local function compare(left, right)
  for index = 1, 3 do
    if left[index] ~= right[index] then return left[index] < right[index] and -1 or 1 end
  end
  return 0
end

local function caret_upper(version)
  local major, minor, patch = version[1], version[2], version[3]
  if major > 0 or minor == nil then return { major + 1, 0, 0 } end
  if minor > 0 or patch == nil then return { 0, minor + 1, 0 } end
  return { 0, 0, patch + 1 }
end

local function comparators_of(token)
  local operator, rest = string.match(token, "^([<>]=?)(.*)$")
  if operator == nil then operator, rest = string.match(token, "^([~^]?)(.*)$") end
  local version = partial(rest)
  if version == nil then return nil end
  if operator == ">=" then return { { ">=", full(version) } } end
  if operator == "<" then
    if #version == 0 then return nil end
    return { { "<", full(version) } }
  end
  if operator == ">" then
    if #version == 0 then return nil end
    if #version == 3 then return { { ">", version } } end
    return { { ">=", bumped(version) } }
  end
  if operator == "<=" then
    if #version == 3 then return { { "<=", version } } end
    if #version == 0 then return {} end
    return { { "<", bumped(version) } }
  end
  if #version == 0 then return {} end
  if operator == "^" then return { { ">=", full(version) }, { "<", caret_upper(version) } } end
  if operator == "~" then
    local upper = #version == 1 and { version[1] + 1, 0, 0 } or { version[1], version[2] + 1, 0 }
    return { { ">=", full(version) }, { "<", upper } }
  end
  if #version == 3 then return { { "=", version } } end
  return { { ">=", full(version) }, { "<", bumped(version) } }
end

local function hyphen_set(low, high)
  local from, to = partial(low), partial(high)
  if from == nil or to == nil then return nil end
  local set = { { ">=", full(from) } }
  if #to == 3 then set[2] = { "<=", to } elseif #to > 0 then set[2] = { "<", bumped(to) } end
  return set
end

local function set_of(text)
  local low, high = string.match(text, "^(%S+)%s+%-%s+(%S+)$")
  if low ~= nil then return hyphen_set(low, high) end
  local normalised = string.gsub(text, "([<>=~^]+)%s+", "%1")
  local set = {}
  for token in string.gmatch(normalised, "%S+") do
    local comparators = comparators_of(token)
    if comparators == nil then return nil end
    for _, comparator in ipairs(comparators) do set[#set + 1] = comparator end
  end
  return set
end

local TESTS = {
  [">="] = function(order) return order >= 0 end, [">"] = function(order) return order > 0 end,
  ["<="] = function(order) return order <= 0 end, ["<"] = function(order) return order < 0 end,
  ["="] = function(order) return order == 0 end,
}

local function satisfies(version, sets)
  for _, set in ipairs(sets) do
    local all = true
    for _, comparator in ipairs(set) do
      if not TESTS[comparator[1]](compare(version, comparator[2])) then all = false break end
    end
    if all then return true end
  end
  return false
end

local function sets_of(range)
  if string.match(range, "^%s*$") then return nil end
  local sets = {}
  for alternative in string.gmatch(range .. "||", "(.-)||") do
    local trimmed = string.match(alternative, "^%s*(.-)%s*$")
    local set = trimmed == "" and {} or set_of(trimmed)
    if set == nil then return nil end
    sets[#sets + 1] = set
  end
  return sets
end

--- The newest pinned node that satisfies an engines.node range, or the newest
--- pinned node when the package names no range at all.
local function newest_satisfying(range)
  local pinned = runtimes.pinned()
  if range == nil then return pinned[1] end
  if type(range) ~= "string" then return nil, string.format(UNREADABLE, tostring(range)) end
  local sets = sets_of(range)
  if sets == nil then return nil, string.format(UNREADABLE, range) end
  for _, text in ipairs(pinned) do
    if satisfies(full(partial(text)), sets) then return text end
  end
  return nil, string.format('no pinned node satisfies the engines.node range "%s": this plugin pins %s',
                            range, table.concat(pinned, ", "))
end

return { newest_satisfying = newest_satisfying }
