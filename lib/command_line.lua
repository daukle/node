local scripts = daukle.require("lib/scripts")

local SHELL_CHARACTER ="[|;<>$`*?(){}~\\&!#%%%^%[%]]"
local SHELL_WORDS = { cd = true, rm = true, cp = true, mv = true, mkdir = true,
                      set = true, export = true, cat = true, test = true,
                      exec = true, time = true, exit = true, ["true"] = true, ["false"] = true,
                      ["if"] = true, ["then"] = true, ["for"] = true, ["while"] = true,
                      source = true, ["."] = true, sh = true, bash = true, zsh = true, dash = true }
local RUNNERS = { npx = true, yarn = true, bun = true, deno = true }

--- pnpm's own commands, which win over a script of the same name in `pnpm <name>`.
local PNPM_COMMANDS = {}
for name in string.gmatch("add audit bin config create dedupe deploy dlx doctor env exec fetch i"
                          .. " import init install install-test it licenses link list ln ls outdated"
                          .. " pack patch patch-commit patch-remove prune publish rb rebuild recursive"
                          .. " remove rm root self-update server setup store un uninstall unlink up"
                          .. " update upgrade why", "%S+") do
  PNPM_COMMANDS[name] = true
end

local SHELL = 'needs a shell, which this toolchain refuses by design: "%s"'
local GLOB_CHARACTER = "[%*%?%[%]]"

--- The characters still active inside double quotes in sh (`$`, a backquote, `\`) or in cmd.exe
--- (`%`, and `!` under delayed expansion), the shells npm hands a script to.
local DOUBLE_QUOTED_SHELL_CHARACTER = "[%$`\\%%!]"

--- Whether a word holds a shell character other than a glob's `*`, `?`, `[` and `]`.
local function has_other_shell_character(word)
  return string.find((string.gsub(word, GLOB_CHARACTER, "")), SHELL_CHARACTER) ~= nil
end

--- Whether what a pair of quotes holds reaches the command as written under both shells.
---
--- @implNote a single-quoted word is held to the unquoted rule, since cmd.exe does not treat a
--- single quote as quoting at all (D-257).
local function is_literal_when_quoted(quote, quoted)
  if quote == '"' then return string.find(quoted, DOUBLE_QUOTED_SHELL_CHARACTER) == nil end
  return not has_other_shell_character(quoted)
end

--[[ An unquoted glob becomes { glob = word }, expanded at run time as sh does,
     and a quoted one is the literal word sh passes (D-227). ]]
local function words_of(text, allows_passed)
  local words, index, length = {}, 1, #text
  while index <= length do
    local character = string.sub(text, index, index)
    if string.match(character, "%s") then
      index = index + 1
    elseif character == '"' or character == "'" then
      local closing = string.find(text, character, index + 1, true)
      if closing == nil then return nil, "has an unterminated quote" end
      local after = string.sub(text, closing + 1, closing + 1)
      if after ~= "" and not string.match(after, "%s") then
        return nil, string.format(SHELL, string.sub(text, index, closing + 1))
      end
      local quoted = string.sub(text, index + 1, closing - 1)
      if allows_passed and character == '"' and quoted == "$@" then
        words[#words + 1] = { passed = true }
      elseif not is_literal_when_quoted(character, quoted) then
        return nil, string.format(SHELL, quoted)
      else
        words[#words + 1] = quoted
      end
      index = closing + 1
    else
      local finish = (string.find(text, "[%s\"']", index) or length + 1) - 1
      local word = string.sub(text, index, finish)
      if string.find(string.sub(text, finish + 1, finish + 1), "[\"']") then
        return nil, string.format(SHELL, word .. string.sub(text, finish + 1, finish + 1))
      end
      if has_other_shell_character(word) then return nil, string.format(SHELL, word) end
      words[#words + 1] = string.find(word, GLOB_CHARACTER) and { glob = word } or word
      index = finish + 1
    end
  end
  return words
end

--- The pieces of a body between `&&` and `||`, and the operator after each but the last.
local function pieces_of(body)
  local pieces, operators, start = {}, {}, 1
  while true do
    local found, _, operator = string.find(body, "([&|][&|])", start)
    while found ~= nil and operator ~= "&&" and operator ~= "||" do
      found, _, operator = string.find(body, "([&|][&|])", found + 1)
    end
    if found == nil then break end
    pieces[#pieces + 1] = string.sub(body, start, found - 1)
    operators[#operators + 1] = operator
    start = found + 2
  end
  pieces[#pieces + 1] = string.sub(body, start)
  return pieces, operators
end

--- The body a `sh -c '<body>' <name>` hands its shell, or nil when the script is not one.
---
--- @implNote only a single-quoted body with a `$0` name and nothing after it: words after the
--- name would become `$1`... for the body, which a step has no way to say.
local function shell_body_of(body)
  return string.match(body, "^%s*sh%s+%-c%s+'([^']*)'%s+[%w_%.%-]+%s*$")
end

local function parse(body)
  if string.find(body, "[\r\n]") then return nil, string.format(SHELL, "a line break") end
  local inner = shell_body_of(body)
  local pieces, operators = pieces_of(inner or body)
  local segments = {}
  for _, piece in ipairs(pieces) do
    local words, reason = words_of(piece, inner ~= nil)
    if words == nil then return nil, reason end
    if #words == 0 then return nil, "has an empty step around \"&&\" or \"||\"" end
    segments[#segments + 1] = words
  end
  return { segments = segments, operators = operators }
end

local function rest_of(words, from)
  local out = {}
  for index = from, #words do out[#out + 1] = words[index] end
  return out
end

--- The words after npm's `--`, which npm appends to the called script's command, or nil and why
--- when words follow the script's name without one: npm would read those as its own options.
local function passed_arguments(words, from, target)
  if words[from] == nil then return {} end
  if words[from] ~= "--" then
    return nil, string.format('passes "%s" to "%s" without "--", which npm reads as its own option',
                              tostring(words[from].glob or words[from]), target)
  end
  return rest_of(words, from + 1)
end

--- The words with npm's `--prefix <dir>` or `--prefix=<dir>` taken out, and the directory.
local function without_prefix(words)
  local kept, prefix = {}, nil
  local index = 1
  while index <= #words do
    local word = words[index]
    if word == "--" then
      for rest = index, #words do kept[#kept + 1] = words[rest] end
      break
    end
    if word == "--prefix" and type(words[index + 1]) == "string" then
      prefix = words[index + 1]
      index = index + 2
    elseif type(word) == "string" and string.sub(word, 1, 9) == "--prefix=" then
      prefix = string.sub(word, 10)
      index = index + 1
    else
      kept[#kept + 1] = word
      index = index + 1
    end
  end
  return kept, prefix
end

--- `npm run <script>`, a shorthand such as `npm test`, and either with `--prefix <dir>`, which
--- runs the script of the package in `<dir>`: a node instance of its own (D-248, D-255).
local function npm_step(words, declared)
  local prefix
  words, prefix = without_prefix(words)
  local verb = words[2]
  local target, from, shorthand
  if (verb == "run" or verb == "run-script") and words[3] ~= nil then
    target, from = words[3], 4
  elseif scripts.NPM_SHORTHANDS[verb] ~= nil then
    target, from, shorthand = scripts.NPM_SHORTHANDS[verb], 3, verb
  else
    return nil, string.format('runs "npm %s", which has no daukle equivalent', tostring(verb))
  end
  if prefix ~= nil then
    if not scripts.is_package_directory(string.gsub(prefix, "^%./", "")) then
      return nil, string.format('runs a script with "--prefix %s", which is not a directory below this'
                                .. ' package', prefix)
    end
    if words[from] ~= nil then
      return nil, string.format('passes arguments to "%s" in "%s", which a nested package\'s script'
                                .. ' step cannot carry yet', target, prefix)
    end
    return { script = target, package = (string.gsub(prefix, "^%./", "")), shorthand = shorthand }
  end
  if not declared[target] then
    return nil, string.format('runs "%s", which is not a declared script', target)
  end
  local args, why = passed_arguments(words, from, target)
  if args == nil then return nil, why end
  if #args == 0 then return { script = target, shorthand = shorthand } end
  return { script = target, args = args, shorthand = shorthand }
end

--- `pnpm run <script>`, `pnpm test`, `pnpm start` and the `pnpm <script>` shorthand, as a script
--- step. Arguments are refused: pnpm hands every word after the name to the script, `--` included
--- in some releases, so there is no one translation of them.
local function pnpm_step(words, declared)
  local verb = words[2]
  if type(verb) ~= "string" then return nil, 'runs "pnpm" with nothing to run' end
  local target, from = verb, 3
  if verb == "dlx" or verb == "exec" then
    return nil, string.format('runs "pnpm %s", which fetches or runs code outside the provisioned node', verb)
  end
  if verb == "run" or verb == "run-script" then
    target, from = words[3], 4
  elseif verb == "t" or verb == "tst" then
    target = "test"
  elseif PNPM_COMMANDS[verb] or string.sub(verb, 1, 1) == "-" then
    return nil, string.format('runs "pnpm %s", which has no daukle equivalent', verb)
  end
  if type(target) ~= "string" or not declared[target] then
    return nil, string.format('runs "%s", which is not a declared script', tostring(target))
  end
  if words[from] ~= nil then
    return nil, string.format('passes arguments to "%s" through pnpm, which a script step cannot carry yet', target)
  end
  return { script = target }
end

local ASSIGNMENT = "^([%a_][%w_]*)=(.*)$"

--- The `NAME=value` words a segment starts with, as an env table or nil, and the words after them.
local function env_prefix(words)
  local env, index = nil, 1
  while type(words[index]) == "string" and string.match(words[index], ASSIGNMENT) do
    local name, value = string.match(words[index], ASSIGNMENT)
    env = env or {}
    env[name] = value
    index = index + 1
  end
  return env, rest_of(words, index)
end

--- `rm` and its flags as a remove step, as `rm` reads them.
local function remove_step(words)
  local step, flag_words = { remove = {} }, {}
  for index = 2, #words do
    local word = words[index]
    if type(word) == "string" and string.match(word, "^%-[rRf]+$") then
      if string.find(word, "[rR]") then step.recursive = true end
      if string.find(word, "f", 1, true) then step.force = true end
      flag_words[#flag_words + 1] = word
    elseif type(word) == "string" and string.sub(word, 1, 1) == "-" then
      return nil, string.format('passes "%s" to rm, which a remove step cannot carry', word)
    else
      step.remove[#step.remove + 1] = word
    end
  end
  if #step.remove == 0 then return nil, 'runs "rm" with nothing to remove' end
  local spelled = table.concat(flag_words, " ")
  if spelled ~= (scripts.remove_flag(step.recursive, step.force) or "") then step.flags = spelled end
  return step
end

--- `echo` as a step printing its words.
---
--- @implNote a flag is refused rather than passed: `-n` and `-e` mean different things to the sh
--- and the cmd.exe npm hands a script to, so there is no one behaviour to translate.
local function echo_step(words)
  local printed = rest_of(words, 2)
  for _, word in ipairs(printed) do
    if type(word) == "string" and string.sub(word, 1, 1) == "-" then
      return nil, string.format('passes "%s" to echo, which a print step cannot carry', word)
    end
  end
  return { echo = printed }
end

local function with_env(step, env)
  if step ~= nil and env ~= nil then step.env = env end
  return step
end

--- A word that expands at run time, as the shell wrote it: a glob, or `"$@"`'s passed arguments.
local function generated_word(word)
  if word.glob ~= nil then return word.glob .. '", a glob' end
  return '$@", the passed arguments'
end

local function step_of(segment, declared)
  local env, words = env_prefix(segment)
  local first = words[1]
  if first == nil then
    return nil, 'only sets environment variables, which a shell keeps for later commands and a step cannot'
  end
  if type(first) ~= "string" then
    return nil, string.format(SHELL, generated_word(first) .. ' naming the command')
  end
  if first == "rm" then
    if env ~= nil then return nil, 'sets environment variables for "rm", which a remove step cannot carry' end
    return remove_step(words)
  end
  if first == "echo" then
    if env ~= nil then return nil, 'sets environment variables for "echo", which a print step cannot carry' end
    return echo_step(words)
  end
  if RUNNERS[first] then
    return nil, string.format('runs "%s", which fetches or runs code outside the provisioned node',
                              first)
  end
  if SHELL_WORDS[first] then return nil, string.format(SHELL, first) end
  if first == "npm" then
    if env ~= nil then return nil, 'sets environment variables for "npm", which a script step cannot carry' end
    return npm_step(words, declared)
  end
  if first == "pnpm" then
    if env ~= nil then return nil, 'sets environment variables for "pnpm", which a script step cannot carry' end
    return pnpm_step(words, declared)
  end
  if first == "node" then
    if words[2] == nil then return nil, 'runs "node" with nothing to run' end
    if type(words[2]) ~= "string" then
      return nil, string.format(SHELL, generated_word(words[2]) .. ' naming the module')
    end
    if string.sub(words[2], 1, 1) == "-" then
      for _, word in ipairs(words) do
        if word == "--run" or (type(word) == "string" and string.sub(word, 1, 6) == "--run=") then
          return nil, 'passes "--run" to node, which runs a script through a shell, refused by design'
        end
      end
      return with_env({ node = rest_of(words, 2) }, env)
    end
    return with_env({ module = words[2], args = rest_of(words, 3) }, env)
  end
  return with_env({ command = first, args = rest_of(words, 2) }, env)
end

return { parse = parse, step_of = step_of }
