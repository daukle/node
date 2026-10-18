--- The relative path from a directory below the project root back up to it.
local function climb_from(dir)
  if dir == nil or dir == "." then return "" end
  local climb = ""
  for _ in string.gmatch(dir, "[^/]+") do climb = climb .. "../" end
  return climb
end

return { climb_from = climb_from }
