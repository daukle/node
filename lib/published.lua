--- The package.json `node:pack` puts in the tarball, rendered from the toolchain's own keys
--- (spec 2026-11-06-npm-packing-design.md, ruling 5.2).
local scripts = daukle.require("lib/scripts")

local published = {}

--- The key holding the consumer-facing fields, each as its raw JSON text.
published.KEY = "package"

--- The fields the table may hold: what npm and a consumer read from a published manifest that no
--- other key of this toolchain already carries.
published.FIELDS = { name = true, version = true, description = true, license = true, author = true,
                     contributors = true, keywords = true, repository = true, homepage = true,
                     bugs = true, private = true, funding = true, main = true, exports = true, files = true,
                     publishConfig = true, packageManager = true }

--- A key of the table that is no field of the manifest, each script's text where it spaces its
--- words differently from what its steps render.
published.SCRIPT_TEXT = "scriptText"

local function json_string(text)
  local escaped = string.gsub(text, '[%c"\\]', function(character)
    if character == '"' then return '\\"' end
    if character == "\\" then return "\\\\" end
    return string.format("\\u%04x", string.byte(character))
  end)
  return '"' .. escaped .. '"'
end

local PLAIN_WORD = "^[%w%-%._/:=@+,%%^~#]+$"

local function word(argument)
  if type(argument) == "table" then return argument.glob or '"$@"' end
  if string.match(argument, PLAIN_WORD) then return argument end
  return '"' .. argument .. '"'
end

local function unscoped(name)
  return string.match(name, "^@[^/]+/(.+)$") or name
end

local function env_words(env)
  local names = {}
  for name in pairs(env or {}) do names[#names + 1] = name end
  table.sort(names)
  local out = {}
  for _, name in ipairs(names) do out[#out + 1] = name .. "=" .. word(env[name]) end
  return out
end

local render_list

local function step_words(step)
  if step.kind == "attempt" then return { render_list(step.attempt), "||", render_list(step.otherwise) } end
  if step.kind == "echo" then
    local words = { "echo" }
    for _, argument in ipairs(step.args) do words[#words + 1] = word(argument) end
    return words
  end
  if step.kind == "remove" then
    local words = { "rm", step.flags or scripts.remove_flag(step.recursive, step.force) }
    for _, path in ipairs(step.paths) do words[#words + 1] = word(path) end
    return words
  end
  local words = env_words(step.env)
  if step.kind == "script" then
    words[#words + 1] = "npm"
    if step.shorthand ~= nil then
      words[#words + 1] = step.shorthand
    else
      words[#words + 1] = "run"
      words[#words + 1] = step.name
    end
    if step.package ~= nil then
      words[#words + 1] = "--prefix"
      words[#words + 1] = word(step.package)
    end
    if #step.args > 0 then words[#words + 1] = "--" end
    for _, argument in ipairs(step.args) do words[#words + 1] = word(argument) end
    return words
  end
  if step.kind == "node" then
    words[#words + 1] = "node"
  elseif step.kind == "module" then
    words[#words + 1] = "node"
    words[#words + 1] = word(step.name)
  else
    words[#words + 1] = step.binName or unscoped(step.name)
  end
  for _, argument in ipairs(step.args) do words[#words + 1] = word(argument) end
  return words
end

--- A script's checked steps as the one command line that parses back to them.
function render_list(steps)
  local segments = {}
  for index, step in ipairs(steps) do segments[index] = table.concat(step_words(step), " ") end
  return table.concat(segments, " && ")
end

--- @implNote a `sh -c` script renders as its body alone, so a packed package declaring one is
--- blocked by the migrator's comparison rather than published changed.
published.render = render_list

local function collapsed(text)
  return (string.gsub(string.gsub(text, "%s+", " "), "^ ?(.-) ?$", "%1"))
end

--- Whether two command lines differ at most in the spaces between and around their words.
function published.same_words(left, right)
  return collapsed(left) == collapsed(right)
end

local function object_of(names, values)
  local parts = {}
  for _, name in ipairs(names) do parts[#parts + 1] = json_string(name) .. ": " .. json_string(values[name]) end
  return "{" .. table.concat(parts, ", ") .. "}"
end

local function sorted(map)
  local names = {}
  for name in pairs(map) do names[#names + 1] = name end
  table.sort(names)
  return names
end

--- `name`'s line as its author spaced it when `scriptText` still holds the same words: an edit to
--- the steps changes the words, and then the steps win.
local function spaced_as_written(exact, name, rendered)
  local text = exact[name]
  if type(text) == "string" and published.same_words(text, rendered) then return text end
  return rendered
end

--- The JSON text of a `scriptText` value.
function published.script_text(texts)
  return object_of(sorted(texts), texts)
end

--- The packed manifest's text: the table's fields, the type, the scripts rendered back, the
--- dependency ranges the lockfile was resolved from, and every carried field.
function published.manifest(spec)
  local members = {}
  for _, name in ipairs(sorted(spec.published)) do
    if name ~= published.SCRIPT_TEXT then members[#members + 1] = json_string(name) .. ": " .. spec.published[name] end
  end
  local exact = spec.published[published.SCRIPT_TEXT] ~= nil and daukle.json_parse(spec.published[published.SCRIPT_TEXT]) or {}
  if spec.type ~= nil then members[#members + 1] = '"type": ' .. json_string(spec.type) end
  if #spec.scripts > 0 or spec.keeps_empty_scripts then
    local script_names, rendered = {}, {}
    for index, script in ipairs(spec.scripts) do
      script_names[index] = script.name
      rendered[script.name] = spaced_as_written(exact, script.name, published.render(script.steps))
    end
    members[#members + 1] = '"scripts": ' .. object_of(script_names, rendered)
  end
  if #spec.packages > 0 then members[#members + 1] = '"dependencies": ' .. object_of(spec.packages, spec.package_ranges) end
  if #spec.dev_packages > 0 then
    members[#members + 1] = '"devDependencies": ' .. object_of(spec.dev_packages, spec.dev_ranges)
  end
  if #spec.peer_packages > 0 then members[#members + 1] = '"peerDependencies": ' .. object_of(spec.peer_packages, spec.peer_ranges) end
  if #spec.optional_packages > 0 then
    members[#members + 1] = '"optionalDependencies": ' .. object_of(spec.optional_packages, spec.optional_ranges)
  end
  if spec.peer_meta ~= nil then members[#members + 1] = '"peerDependenciesMeta": ' .. spec.peer_meta end
  for _, name in ipairs(spec.field_names or {}) do members[#members + 1] = json_string(name) .. ": " .. spec.fields[name] end
  return "{\n  " .. table.concat(members, ",\n  ") .. "\n}\n"
end

return published
