--- A script argument's glob, expanded as POSIX `sh` does before it runs a
--- command, with no shell (spec D-227, the 2026-11-04 corpus backlog design,
--- section 5).
---
--- @implNote `sh` semantics on every host, because the reference builds ran
--- under `sh`; cmd.exe would have passed the pattern through unexpanded. `**`
--- is `*`, as `sh` without globstar reads it.
local glob = {}

local GLOB_CHARACTER = "[%*%?%[]"

function glob.is_pattern(word)
  return string.find(word, GLOB_CHARACTER) ~= nil
end

--- The bracket expression at `index`, a `[`, as a Lua class, and the index after it; nil when unclosed.
local function bracket_at(component, index)
  local finish = string.find(component, "]", index + 2, true)
  if finish == nil then return nil end
  local body = string.sub(component, index + 1, finish - 1)
  local negated = string.match(body, "^[!%^]") ~= nil
  if negated then body = string.sub(body, 2) end
  body = string.gsub(body, "([%%%]%^])", "%%%1")
  return "[" .. (negated and "^" or "") .. body .. "]", finish + 1
end

--- One path component's pattern as an anchored Lua pattern.
local function lua_pattern_of(component)
  local out, index = { "^" }, 1
  while index <= #component do
    local character = string.sub(component, index, index)
    local class, after = nil, index + 1
    if character == "*" then
      class = ".*"
    elseif character == "?" then
      class = "."
    elseif character == "[" then
      class, after = bracket_at(component, index)
      if class == nil then class, after = "%[", index + 1 end
    else
      class = string.gsub(character, "(%W)", "%%%1")
    end
    out[#out + 1] = class
    index = after
  end
  out[#out + 1] = "$"
  return table.concat(out)
end

local function components_of(text)
  local components = {}
  for component in string.gmatch(text, "[^/]+") do components[#components + 1] = component end
  return components
end

local function components_match(pattern, path, pattern_index, path_index)
  if pattern_index > #pattern then return path_index > #path end
  if pattern[pattern_index] == "**" then
    for skipped = path_index, #path + 1 do
      if components_match(pattern, path, pattern_index + 1, skipped) then return true end
    end
    return false
  end
  return path_index <= #path and string.match(path[path_index], lua_pattern_of(pattern[pattern_index])) ~= nil
         and components_match(pattern, path, pattern_index + 1, path_index + 1)
end

--- Whether a relative path matches a pattern, `*` and `?` within one component and a `**`
--- component spanning any number of them, as pnpm reads a workspace's `packages` globs.
function glob.matches(pattern, path)
  return components_match(components_of(pattern), components_of(path), 1, 1)
end

local function joined(directory, name)
  if directory == "" then return name end
  return directory .. "/" .. name
end

local function listed(root, directory)
  local entries = daukle.list(joined(root, directory) == "" and "." or joined(root, directory))
  return entries or {}
end

--- The entries of `directory` (relative to `root`) that one component names.
---
--- @implNote `.` and `..` are kept as written and never listed, as `sh` keeps
--- `./lib/*.js` as `./lib/a.js`; no directory lists them as entries.
local function matches_of(root, directory, component, is_last)
  local found = {}
  if component == "." or component == ".." then return { joined(directory, component) } end
  if not glob.is_pattern(component) then
    for _, entry in ipairs(listed(root, directory)) do
      if entry.name == component and (is_last or entry.kind ~= "file") then
        found[#found + 1] = joined(directory, entry.name)
      end
    end
    return found
  end
  local pattern = lua_pattern_of(component)
  local shows_hidden = string.sub(component, 1, 1) == "."
  for _, entry in ipairs(listed(root, directory)) do
    local hidden = string.sub(entry.name, 1, 1) == "."
    if (shows_hidden or not hidden) and string.match(entry.name, pattern)
       and (is_last or entry.kind ~= "file") then
      found[#found + 1] = joined(directory, entry.name)
    end
  end
  return found
end

--- The paths `pattern` names under `root` (a directory relative to the project),
--- sorted, as `sh` would pass them; the pattern itself when it names nothing.
function glob.expand(root, pattern)
  local components = components_of(pattern)
  local candidates = { "" }
  for index, component in ipairs(components) do
    local next_candidates = {}
    for _, directory in ipairs(candidates) do
      for _, path in ipairs(matches_of(root, directory, component, index == #components)) do
        next_candidates[#next_candidates + 1] = path
      end
    end
    candidates = next_candidates
  end
  if #candidates == 0 then return { pattern } end
  table.sort(candidates)
  return candidates
end

return glob
