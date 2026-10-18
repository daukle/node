daukle.plugin{ api = 1, uses = { "write", "json_parse" } }

daukle.toolchain{ name = "unit", generate = function() return {} end }

local SUITES = {
  engines_test = daukle.require("tests/engines_test"),
  command_line_test = daukle.require("tests/command_line_test"),
  translate_test = daukle.require("tests/translate_test"),
  npm_errors_test = daukle.require("tests/npm_errors_test"),
}
local SUITE_ORDER = { "engines_test", "command_line_test", "translate_test", "npm_errors_test" }

daukle.task{
  name = "unit:test",
  run = function()
    local failures, count = {}, 0
    for _, suite in ipairs(SUITE_ORDER) do
      for _, case in ipairs(SUITES[suite]) do
        count = count + 1
        local problem = case.check()
        if problem ~= nil then failures[#failures + 1] = suite .. ": " .. case.name .. ": " .. problem end
      end
    end
    if #failures > 0 then
      error(#failures .. " of " .. count .. " failed:\n" .. table.concat(failures, "\n"), 0)
    end
    daukle.write{ path = "unit.txt", text = count .. " passed\n" }
  end,
}
