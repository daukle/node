local SHELL_CHARACTER = "[|;<>$`*?(){}~\\&!#]"
local SHELL_WORDS = { cd = true, rm = true, cp = true, mv = true, mkdir = true, echo = true,
                      set = true, export = true, cat = true, test = true }
local RUNNERS = { npx = true, pnpm = true, yarn = true, bun = true, deno = true }
local NPM_SCRIPT_VERBS = { test = "test", t = "test", start = "start", stop = "stop",
                           restart = "restart" }

local SHELL = 'needs a shell, which this toolchain refuses by design: "%s"'

--[[ @implNote a quoted word is unquoted only when what it quotes holds no
     shell character, because npm hands the body to sh on one host and cmd.exe
     on another, and the two disagree about what a quoted metacharacter does. ]]
local function words_of(text)
  local words, index, length = {}, 1, #text
  while index <= length do
    local character = string.sub(text, index, index)
    if string.match(character, "%s") then
      index = index + 1
    elseif character == '"' or character == "'" then
      local closing = string.find(text, character, index + 1, true)
      if closing == nil then return nil, "has an unterminated quote" end
      local quoted = string.sub(text, index + 1, closing - 1)
      if string.find(quoted, SHELL_CHARACTER) then return nil, string.format(SHELL, quoted) end
      words[#words + 1] = quoted
      index = closing + 1
    else
      local finish = (string.find(text, "[%s\"']", index) or length + 1) - 1
      local word = string.sub(text, index, finish)
      if string.find(word, SHELL_CHARACTER) then return nil, string.format(SHELL, word) end
      words[#words + 1] = word
      index = finish + 1
    end
  end
  return words
end

local function parse(body)
  local segments = {}
  for piece in string.gmatch(body .. "&&", "(.-)&&") do
    local words, reason = words_of(piece)
    if words == nil then return nil, reason end
    if #words == 0 then return nil, "has an empty step around \"&&\"" end
    segments[#segments + 1] = words
  end
  return { segments = segments }
end

local function rest_of(words, from)
  local out = {}
  for index = from, #words do out[#out + 1] = words[index] end
  return out
end

local function npm_step(words, declared)
  local verb = words[2]
  local target
  if (verb == "run" or verb == "run-script") and words[3] ~= nil then
    if #words > 3 then return nil, string.format('passes arguments to "%s", and a script step takes'
                                                  .. ' none', words[3]) end
    target = words[3]
  elseif NPM_SCRIPT_VERBS[verb] ~= nil and #words == 2 then
    target = NPM_SCRIPT_VERBS[verb]
  else
    return nil, string.format('runs "npm %s", which has no daukle equivalent', tostring(verb))
  end
  if not declared[target] then
    return nil, string.format('runs "%s", which is not a declared script', target)
  end
  return { script = target }
end

local function step_of(words, declared)
  local first = words[1]
  if string.match(first, "^[%a_][%w_]*=") then
    return nil, string.format('sets an environment variable with "%s", which needs a shell', first)
  end
  if RUNNERS[first] then
    return nil, string.format('runs "%s", which fetches or runs code outside the provisioned node',
                              first)
  end
  if SHELL_WORDS[first] then return nil, string.format(SHELL, first) end
  if first == "npm" then return npm_step(words, declared) end
  if first == "node" then
    if words[2] == nil then return nil, 'runs "node" with nothing to run' end
    if string.sub(words[2], 1, 1) == "-" then
      return nil, string.format('passes the flag "%s" to node, which a module step cannot carry',
                                words[2])
    end
    return { module = words[2], args = rest_of(words, 3) }
  end
  return { command = first, args = rest_of(words, 2) }
end

return { parse = parse, step_of = step_of }
