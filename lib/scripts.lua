--[[ The scripts map, which is what makes a package's SECOND entry point
     reachable. A package.json carries a scripts map and this toolchain modelled
     one "entry", so a project with two of them had one task. ]]

local LIFECYCLE_TASKS = { install = true, run = true }

local STEP_KINDS = { module = true, bin = true, script = true }

--[[ @implNote npm spells a hierarchy with a colon and a daukle task name holds
     at most one, which is the toolchain prefix. A dot is legal and NOT ONE of
     this tree's 904 script names contains one, against 137 that contain a
     hyphen, so "." is the separator that cannot collide with a name a project
     already has. The mapping is one way on purpose: the npm script keeps its
     own spelling and only the task name is mapped. ]]
local function task_name_of(script_name)
  return (string.lower((string.gsub(script_name, ":", "."))))
end

local function checked_script_name(name)
  if type(name) ~= "string" or name == "" then
    error('every key of "scripts" names a script, and "' .. tostring(name) .. '" is not a name', 0)
  end
  local task = task_name_of(name)
  if string.match(task, "^[%l%d%.%_%-]+$") == nil then
    error(string.format('"%s" is a script this toolchain cannot name a task after: a task name is'
                        .. ' lowercase letters, digits, ".", "_" and "-", and a ":" becomes a "."'
                        .. ' , which leaves "%s"', name, task), 0)
  end
  if LIFECYCLE_TASKS[task] then
    error(string.format('a script may not be called "%s": "node:%s" is a lifecycle verb this'
                        .. ' toolchain declares itself', name, task), 0)
  end
  return task
end

local function checked_args(args, where)
  if args == nil then return {} end
  if type(args) ~= "table" then
    error(string.format('%s has "args" that is a %s, and args is a list of strings',
                        where, type(args)), 0)
  end
  local out = {}
  for index = 1, #args do
    if type(args[index]) ~= "string" then
      error(string.format('%s has an argument that is a %s, and every argument is a string',
                          where, type(args[index])), 0)
    end
    out[index] = args[index]
  end
  return out
end

--[[ A step is a ONE-KEY table rather than a command string, so that nothing
     here has to guess where a word ends. A string would also be the place a
     shell crept in: 7% of this tree's npm scripts need true shell features and
     they are refused by name instead, because daukle's answer to them is
     already decided. ]]
local function checked_step(step, where)
  if type(step) ~= "table" then
    error(string.format('%s is a %s, and a step is a table naming one of "module", "bin" or'
                        .. ' "script". A command line is deliberately not a step: for a program'
                        .. ' daukle does not provision, use a manifest task\'s'
                        .. ' run = { tool, args }', where, type(step)), 0)
  end
  local kind
  for key in pairs(step) do
    if STEP_KINDS[key] then
      if kind ~= nil then
        error(string.format('%s names both "%s" and "%s", and a step does exactly one thing',
                            where, kind, key), 0)
      end
      kind = key
    elseif key ~= "args" and key ~= "binName" then
      error(string.format('"%s" is not a key a step knows, in %s: a step names one of "module",'
                          .. ' "bin" or "script". There is no shell and no "npx": for anything'
                          .. ' else, use a manifest task\'s run = { tool, args }', key, where), 0)
    end
  end
  if kind == nil then
    error(string.format('%s names none of "module", "bin" or "script", so it does nothing',
                        where), 0)
  end
  if type(step[kind]) ~= "string" or step[kind] == "" then
    error(string.format('%s has a "%s" that is not a name', where, kind), 0)
  end
  if kind == "script" and (step.args ~= nil or step.binName ~= nil) then
    error(string.format('%s runs another script, which takes no arguments of its own', where), 0)
  end
  if kind ~= "bin" and step.binName ~= nil then
    error(string.format('%s has a "binName" without a "bin"', where), 0)
  end
  return { kind = kind, name = step[kind], args = checked_args(step.args, where),
           binName = step.binName }
end

local function steps_of(value, where)
  if type(value) ~= "table" then
    error(string.format('%s is a %s, and a script is a step or a list of steps', where,
                        type(value)), 0)
  end
  -- A single step is itself a table, so the list form is told apart by having
  -- an element at index 1 rather than by counting keys.
  if value[1] == nil then return { checked_step(value, where) } end
  local out = {}
  for index = 1, #value do
    out[index] = checked_step(value[index], string.format("%s step %d", where, index))
  end
  return out
end

--[[ A missing reference and a cycle are both properties of the manifest alone,
     so they are refused where sync can see them rather than when the task runs:
     a script that calls itself would otherwise provision a runtime and recurse
     until something else gave way. ]]
local function reject_unreachable_references(declared)
  local by_name = {}
  for index = 1, #declared do by_name[declared[index].name] = declared[index] end

  local function walk(script, path, on_path)
    for index = 1, #script.steps do
      local step = script.steps[index]
      if step.kind == "script" then
        local target = by_name[step.name]
        if target == nil then
          error(string.format('scripts."%s" runs "%s", which is not a declared script',
                              script.name, step.name), 0)
        end
        if on_path[step.name] then
          error(string.format('scripts."%s" runs itself again, through %s', step.name,
                              table.concat(path, " -> ")), 0)
        end
        on_path[step.name] = true
        path[#path + 1] = step.name
        walk(target, path, on_path)
        path[#path] = nil
        on_path[step.name] = nil
      end
    end
  end

  for index = 1, #declared do
    local script = declared[index]
    walk(script, { script.name }, { [script.name] = true })
  end
end

local function sorted_names(scripts)
  local names = {}
  for name in pairs(scripts) do names[#names + 1] = name end
  table.sort(names)
  return names
end

--- Every declared script, as a LIST, in a deterministic order. The caller never
--- branches on how many there are: a project with one script is the same loop
--- as a project with twelve, which is the whole reason this key exists.
local function read(config)
  local scripts = config.scripts
  if scripts == nil then return {} end
  if type(scripts) ~= "table" then
    error('"scripts" must be a table of script name to step, not a ' .. type(scripts), 0)
  end
  if #scripts > 0 then
    error('"scripts" must be a table of script name to step, not a list: a list says nothing'
          .. ' about what any of them is called', 0)
  end

  local out = {}
  local seen = {}
  for _, name in ipairs(sorted_names(scripts)) do
    local task = checked_script_name(name)
    if seen[task] ~= nil then
      error(string.format('"%s" and "%s" are different scripts and the same daukle task'
                          .. ' "node:%s"', seen[task], name, task), 0)
    end
    seen[task] = name
    out[#out + 1] = { name = name, task = task,
                      steps = steps_of(scripts[name], string.format('scripts."%s"', name)) }
  end
  reject_unreachable_references(out)
  return out
end

--- The names alone, for the chunk that registers one task each. It takes a
--- parsed document rather than a toolchain context, because registration
--- happens before any context exists.
local function task_scripts(document)
  local toolchains = document.toolchains
  local config = toolchains ~= nil and toolchains.node or nil
  if type(config) ~= "table" then return {} end
  return read(config)
end

return { read = read, task_scripts = task_scripts, task_name_of = task_name_of }
