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
  steps("rm -rf dist", { { remove = { "dist" }, recursive = true, force = true } }),
  steps("rm -f a.log b.log", { { remove = { "a.log", "b.log" }, force = true } }),
  steps("rm dist/*.js", { { remove = { { glob = "dist/*.js" } } } }),
  refuses("rm -i dist", "remove step"),
  refuses("rm -rf", "nothing to remove"),
  steps("NODE_ENV=production node app.js", { { module = "app.js", args = {}, env = { NODE_ENV = "production" } } }),
  steps("A=1 B= tsc -p .", { { command = "tsc", args = { "-p", "." }, env = { A = "1", B = "" } } }),
  refuses("A=1", "only sets environment variables"),
  refuses("A=1 npm test", "script step"),
  steps("mocha test/*.spec.js", { { command = "mocha", args = { { glob = "test/*.spec.js" } } } }),
  steps("eslint 'lib/**/*.js'", { { command = "eslint", args = { "lib/**/*.js" } } }),
  refuses("*.sh", "glob naming the command"),
  refuses("node src/*.js", "glob naming the module"),
  refuses("eslint . | tee out", "shell"),
  steps("a || b", { { command = "a", args = {} }, { command = "b", args = {} } }),
  refuses("a |& b", "shell"),
  refuses("bash scripts/dev.sh", 'needs a shell, which this toolchain refuses by design: "bash"'),
  refuses("a & b", "shell"),
  steps("echo '' done", { { echo = { "", "done" } } }),
  refuses("cd web && npm run build", "shell"),
  refuses("npx tsc", "npx"),
  refuses("bun run x", "bun"),
  refuses("node --watch app.js", "flag"),
  refuses("node", "nothing to run"),
  refuses("npm install", "npm install"),
  refuses("npm run lint", "not a declared script"),
  steps("npm run build -- --watch", { { script = "build", args = { "--watch" } } }),
  refuses("npm run build --watch", "without \"--\""),
  refuses("npm run build &&", "empty"),
  refuses("&& npm run build", "empty"),
  refuses('eslint "src', "unterminated"),
  steps('eslint "a*b"', { { command = "eslint", args = { "a*b" } } }),
  refuses("a & b", "shell"),
  refuses("tsc\nrm -rf dist", "shell"),
  refuses("tsc\r\nrm -rf dist", "shell"),
  refuses('eslint src"dir"', "shell"),
  refuses('eslint --ext=".js,.ts" src', "shell"),
  refuses("'a''b'", "shell"),
  refuses('eslint "%PATH%"', "shell"),
  refuses("tsc a^b", "shell"),
  steps("eslint src/[ab].js", { { command = "eslint", args = { { glob = "src/[ab].js" } } } }),
  refuses("exec tsc", "shell"),
}
