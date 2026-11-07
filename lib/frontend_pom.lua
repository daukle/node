--- The node a `frontend-maven-plugin` in a pom.xml installs to build the package beside it (D-237).
---
--- @implNote read with patterns, not an XML parser: this plugin requires nothing across a plugin
--- boundary, and the plugin's own configuration is flat elements holding text.

local NAME = "pom.xml"
local CONSTRUCT = "frontend-maven-plugin"

local THIS_DIRECTORY = { ["."] = true, ["./"] = true, ["${basedir}"] = true, ["${project.basedir}"] = true }

local function trimmed(text)
  return string.match(text, "^%s*(.-)%s*$")
end

local function without_comments(text)
  return (string.gsub(text, "<!%-%-.-%-%->", ""))
end

local function properties_of(text)
  local properties = {}
  for block in string.gmatch(text, "<properties>(.-)</properties>") do
    for name, value in string.gmatch(block, "<([%w%.%-_]+)>(.-)</%1>") do properties[name] = trimmed(value) end
  end
  return properties
end

local function frontend_plugins(text)
  local plugins = {}
  for block in string.gmatch(text, "<plugin>(.-)</plugin>") do
    if string.match(block, "<artifactId>%s*frontend%-maven%-plugin%s*</artifactId>") then
      plugins[#plugins + 1] = block
    end
  end
  return plugins
end

--- Whether the plugin runs in the pom's own directory, its default, rather than in one it names.
local function runs_beside_the_pom(plugin, properties)
  local directory = string.match(plugin, "<workingDirectory>(.-)</workingDirectory>")
  if directory == nil then return true end
  directory = trimmed(directory)
  local name = string.match(directory, "^%${(.-)}$")
  if name ~= nil and properties[name] ~= nil then directory = properties[name] end
  return THIS_DIRECTORY[directory] == true
end

local function pin_of(value, properties)
  value = trimmed(value)
  local name = string.match(value, "^%${(.-)}$")
  if name == nil then return { version = value } end
  if properties[name] == nil then return { unresolved = value } end
  return { version = properties[name] }
end

--- Each distinct `nodeVersion` the pom's frontend-maven-plugin declares for the package beside it,
--- as `{ version = text }`, or `{ unresolved = "${name}" }` for a property the pom does not define.
local function node_pins(text)
  text = without_comments(text or "")
  local properties = properties_of(text)
  local pins, seen = {}, {}
  for _, plugin in ipairs(frontend_plugins(text)) do
    if runs_beside_the_pom(plugin, properties) then
      for value in string.gmatch(plugin, "<nodeVersion>(.-)</nodeVersion>") do
        local pin = pin_of(value, properties)
        local key = pin.version or pin.unresolved
        if not seen[key] then
          seen[key] = true
          pins[#pins + 1] = pin
        end
      end
    end
  end
  return pins
end

return { NAME = NAME, CONSTRUCT = CONSTRUCT, node_pins = node_pins }
