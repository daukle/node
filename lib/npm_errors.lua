local RESOLUTION_CODES = {
  ETARGET = true, E404 = true, ERESOLVE = true, EUNSUPPORTEDPROTOCOL = true,
  EINVALIDTAGNAME = true, E401 = true, E403 = true,
}

local CONFLICT_PATTERNS = { "^Could not resolve dependency", "^peer ", "^Conflicting peer dependency" }
local NOISE_PATTERNS = { "^code ", "^errno ", "^syscall ", "^at ", "^%l[%w_]*: ", "^[{}]$" }
local LOG_PATTERN = "^A complete log of this run"
local SHOWN_LINES = 3

local function matches_any(text, patterns)
  for _, pattern in ipairs(patterns) do
    if string.match(text, pattern) then return true end
  end
  return false
end

local function error_lines(stderr)
  local lines = {}
  for line in string.gmatch(stderr .. "\n", "(.-)\r?\n") do
    local message = string.match(line, "^npm error%s*(.-)%s*$")
    if message ~= nil and message ~= "" then lines[#lines + 1] = message end
  end
  return lines
end

local function code_of(lines)
  for _, line in ipairs(lines) do
    local code = string.match(line, "^code (%S+)$")
    if code ~= nil then return code end
  end
  return nil
end

local function first_matching(lines, keep)
  local picked = {}
  for _, line in ipairs(lines) do
    if #picked < SHOWN_LINES and keep(line) then
      picked[#picked + 1] = (string.gsub(line, ":$", ""))
    end
  end
  return picked
end

local function is_explanation(line)
  return not matches_any(line, NOISE_PATTERNS) and not string.match(line, LOG_PATTERN)
end

local function is_conflict(line)
  return matches_any(line, CONFLICT_PATTERNS)
end

local function summary(lines)
  local picked = first_matching(lines, is_conflict)
  if #picked == 0 then picked = first_matching(lines, is_explanation) end
  for _, line in ipairs(lines) do
    if string.match(line, LOG_PATTERN) then picked[#picked + 1] = line end
  end
  return table.concat(picked, "; ")
end

--[[ @implNote only a code naming the declared dependencies makes the install a
     property of the project; a network, disk or permission failure is the
     host's, and blocking on it would tell the author to change a project that
     is fine. ]]
local function of_install(stderr, exit_code)
  local lines = error_lines(stderr)
  local message = summary(lines)
  if message == "" then message = "npm exited with code " .. exit_code end
  return { resolution = RESOLUTION_CODES[code_of(lines) or ""] == true, message = message }
end

return { of_install = of_install }
