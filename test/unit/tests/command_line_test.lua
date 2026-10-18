local command_line = daukle.require("lib/command_line")
local expect = daukle.require("tests/expect")

local DECLARED = { build = true, test = true, start = true }

local function steps(body, wanted)
  return { name = "translates " .. body, check = function()
    local parsed, reason = command_line.parse(body)
    if parsed == nil then return "refused: " .. reason end
    local out = {}
    for index, words in ipairs(parsed.segments) do
      local step, why = command_line.step_of(words, DECLARED)
      if step == nil then return "segment " .. index .. " refused: " .. why end
      out[index] = step
    end
    return expect.equal(out, wanted)
  end }
end

local function refuses(body, needle)
  return { name = "refuses " .. body, check = function()
    local parsed, reason = command_line.parse(body)
    if parsed ~= nil then
      for _, words in ipairs(parsed.segments) do
        local step, why = command_line.step_of(words, DECLARED)
        if step == nil then reason = why break end
      end
      if reason == nil then return "wanted a refusal" end
    end
    return expect.contains(reason, needle)
  end }
end

return {
  steps("node src/main.js", { { module = "src/main.js", args = {} } }),
  steps("node  src/main.js\t--port 8080 ", { { module = "src/main.js", args = { "--port", "8080" } } }),
  steps("tsc -p .", { { command = "tsc", args = { "-p", "." } } }),
  steps("npm run build && npm test", { { script = "build" }, { script = "test" } }),
  steps("npm t", { { script = "test" } }),
  steps("npm start", { { script = "start" } }),
  steps('eslint "src dir"', { { command = "eslint", args = { "src dir" } } }),
  steps("eslint 'src'", { { command = "eslint", args = { "src" } } }),
  refuses("rm -rf dist", "shell"),
  refuses("eslint . | tee out", "shell"),
  refuses("a || b", "shell"),
  refuses("NODE_ENV=production node app.js", "environment"),
  refuses("cd web && npm run build", "shell"),
  refuses("npx tsc", "npx"),
  refuses("bun run x", "bun"),
  refuses("node --watch app.js", "flag"),
  refuses("node", "nothing to run"),
  refuses("npm install", "npm install"),
  refuses("npm run lint", "not a declared script"),
  refuses("npm run build -- --watch", "arguments"),
  refuses("npm run build &&", "empty"),
  refuses("&& npm run build", "empty"),
  refuses('eslint "src', "unterminated"),
  refuses('eslint "a*b"', "shell"),
  refuses("a & b", "shell"),
  refuses("tsc\nrm -rf dist", "shell"),
  refuses("tsc\r\nrm -rf dist", "shell"),
  refuses('eslint src"dir"', "shell"),
  refuses('eslint --ext=".js,.ts" src', "shell"),
  refuses("'a''b'", "shell"),
  refuses('eslint "%PATH%"', "shell"),
  refuses("tsc a^b", "shell"),
  refuses("eslint src/[ab].js", "shell"),
  refuses("exec tsc", "shell"),
}
