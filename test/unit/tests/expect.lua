local function render(value)
  if type(value) ~= "table" then return string.format("%q", tostring(value)) end
  local keys = {}
  for key in pairs(value) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local parts = {}
  for _, key in ipairs(keys) do parts[#parts + 1] = tostring(key) .. "=" .. render(value[key]) end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function equal(actual, expected)
  if render(actual) == render(expected) then return nil end
  return "wanted " .. render(expected) .. ", got " .. render(actual)
end

local function contains(text, needle)
  if type(text) == "string" and string.find(text, needle, 1, true) then return nil end
  return "wanted text holding " .. string.format("%q", needle) .. ", got " .. render(text)
end

return { equal = equal, contains = contains, render = render }
