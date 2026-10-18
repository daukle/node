local translate = daukle.require("lib/translate")
local expect = daukle.require("tests/expect")

local function joined(blockers)
  local out = {}
  for _, blocker in ipairs(blockers) do
    out[#out + 1] = blocker.construct .. " " .. blocker.why .. " " .. (blocker.surface or "")
  end
  return table.concat(out, "\n")
end

local function translates(text, wanted)
  return { name = "translates " .. text, check = function()
    local result = translate.package(text, "package.json")
    if #result.blockers > 0 then return "blocked: " .. joined(result.blockers) end
    return expect.equal(result.config, wanted)
  end }
end

local function blocked(text, needle)
  return { name = "blocks " .. needle .. " in " .. text, check = function()
    return expect.contains(joined(translate.package(text, "package.json").blockers), needle)
  end }
end

local function resolves(bins, wanted_step)
  return { name = "resolves a command against " .. expect.render(bins), check = function()
    local result = translate.package('{"scripts":{"build":"tsc -p ."}}', "package.json")
    local blockers = translate.resolve_commands(result.config, bins, "package.json")
    if #blockers > 0 then return "blocked: " .. joined(blockers) end
    return expect.equal(result.config.scripts.build, wanted_step)
  end }
end

local function command_blocked(bins, needle)
  return { name = "blocks the command against " .. expect.render(bins), check = function()
    local result = translate.package('{"scripts":{"build":"tsc -p ."}}', "package.json")
    return expect.contains(joined(translate.resolve_commands(result.config, bins, "package.json")),
                           needle)
  end }
end

local function provider(name, map)
  return { name = name, map = map }
end

return {
  translates('{}', { version = "26.3.1" }),
  translates('\239\187\191{"name":"x"}', { version = "26.3.1" }),
  translates('{\r\n  "private": true,\r\n  "version": "1.0.0"\r\n}\r\n', { version = "26.3.1" }),
  translates('{"dependencies":{"semver":"^7.6.0"},"devDependencies":{"@types/node":"22.0.0"}}',
             { version = "26.3.1", packages = { semver = "^7.6.0" },
               devPackages = { ["@types/node"] = "22.0.0" } }),
  translates('{"engines":{"node":"^22"}}', { version = "22.15.0" }),
  translates('{"type":"module","main":"./src/index.js"}',
             { version = "26.3.1", type = "module", entry = "src/index.js" }),
  translates('{"private":true,"main":"lib.js","scripts":{"start":"node app.js"}}',
             { version = "26.3.1", scripts = { start = { module = "app.js", args = {} } } }),
  translates('{"scripts":{"all":"npm run a && npm run b","a":"node a.js","b":"node b.js"}}',
             { version = "26.3.1", scripts = {
               all = { { script = "a" }, { script = "b" } },
               a = { module = "a.js", args = {} }, b = { module = "b.js", args = {} } } }),
  translates('{"scripts":{}}', { version = "26.3.1" }),
  blocked('{"workspaces":["a"]}', "workspaces"),
  blocked('{"overrides":{"a":"1"}}', "overrides"),
  blocked('{"peerDependencies":{"a":"1"}}', "peerDependencies"),
  blocked('{"bin":"cli.js"}', "bin"),
  blocked('{"somethingNew":1}', "somethingNew"),
  blocked('{"engines":{"node":"<20"}}', "no pinned node"),
  blocked('{"main":"lib.js","scripts":{"start":"node app.js"}}', "main"),
  blocked('{"scripts":{"pretest":"node a.js","test":"node b.js"}}', "pretest"),
  blocked('{"scripts":{"prepublishOnly":"node a.js"}}', "prepublishOnly"),
  blocked('{"scripts":{"postinstall":"node a.js"}}', "postinstall"),
  blocked('{"scripts":{"clean":"rm -rf dist"}}', "NPM-SURFACE.md"),
  blocked('{"scripts":{"Build":"node a.js","build":"node b.js"}}', "same daukle task"),
  blocked('{"scripts":{"run":"node a.js"}}', "lifecycle verb"),
  blocked('{"dependencies":{"a":"https://x.test/a.tgz?x=1"}}', "tarball"),
  blocked('{"dependencies":["a"]}', "dependencies"),
  blocked('not json', "package.json"),
  resolves({ tsc = { provider("typescript", true) } },
           { bin = "typescript", binName = "tsc", args = { "-p", "." } }),
  resolves({ tsc = { provider("tsc", false) } }, { bin = "tsc", args = { "-p", "." } }),
  resolves({ tsc = { provider("tsc", true) } }, { bin = "tsc", args = { "-p", "." } }),
  resolves({ tsc = { provider("@scope/tsc", false) } }, { bin = "@scope/tsc", args = { "-p", "." } }),
  resolves({ tsc = { provider("@scope/tsc", true) } },
           { bin = "@scope/tsc", binName = "tsc", args = { "-p", "." } }),
  command_blocked({}, "no direct dependency provides"),
  command_blocked({ tsc = { provider("a", true), provider("b", false) } }, "both a and b"),
}
