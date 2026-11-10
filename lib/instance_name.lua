local M = {}

local function escaped_byte(character)
  return string.format("_%02x", string.byte(character))
end

--- The instance core names for the package in `dir`, `node` at the project root.
---
--- @implNote mirrors `spell_instance` in core's `migrate_sessions.c`, which migrates each directory
--- separately: a root's install and a script's nested task must name a member core has not reached.
function M.of(dir)
  if dir == nil then return "node" end
  local spelled = string.gsub(dir, "[^a-z0-9._/%-]", escaped_byte)
  return "node-" .. (string.gsub(spelled, "/", "-"))
end

return M
