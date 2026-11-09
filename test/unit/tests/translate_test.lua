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

local MEMBER = { keeps_file_range = function(range) return range == "file:../a" end }

local function member_keeps(text, key, name, range)
  return { name = "a workspace member keeps " .. range .. " in " .. text, check = function()
    local result = translate.package(text, "package.json", MEMBER)
    if #result.blockers > 0 then return "blocked: " .. joined(result.blockers) end
    return expect.equal(result.config[key], { [name] = range })
  end }
end

local function member_blocked(text, needle)
  return { name = "a workspace member blocks " .. needle .. " in " .. text, check = function()
    return expect.contains(joined(translate.package(text, "package.json", MEMBER).blockers), needle)
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

local function resolves_for_a_member(bins, root_bins, wanted_step)
  return { name = "resolves a member's command against " .. expect.render(bins) .. " and " .. expect.render(root_bins), check = function()
    local result = translate.package('{"scripts":{"build":"tsc -p ."}}', "package.json")
    local blockers = translate.resolve_commands(result.config, bins, "package.json", root_bins)
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
  translates('{"engines":{"node":"^22"}}', { version = "22.15.0", packageFields = { engines = '{"node":"^22"}' } }),
  translates('{"engines":{"node":"^22","npm":">=10"}}',
             { version = "22.15.0", packageFields = { engines = '{"node":"^22","npm":">=10"}' } }),
  translates('{"engines":{"npm":">=11.17"}}',
             { version = "24.21.0", packageFields = { engines = '{"npm":">=11.17"}' } }),
  translates('{"engines":{"yarn":"^1"}}', { version = "26.3.1", packageFields = { engines = '{"yarn":"^1"}' } }),
  translates('{"type":"module","main":"./src/index.js"}',
             { version = "26.3.1", type = "module", entry = "src/index.js" }),
  translates('{"private":true,"main":"lib.js","scripts":{"start":"node app.js"}}',
             { version = "26.3.1", scripts = { start = { module = "app.js", args = {} } } }),
  translates('{"scripts":{"all":"npm run a && npm run b","a":"node a.js","b":"node b.js"}}',
             { version = "26.3.1", scripts = {
               all = { { script = "a" }, { script = "b" } },
               a = { module = "a.js", args = {} }, b = { module = "b.js", args = {} } } }),
  translates('{"scripts":{}}', { version = "26.3.1" }),
  translates('{"scripts":{"a":"node a.js || node b.js"}}',
             { version = "26.3.1", scripts = { a = { attempt = { { module = "a.js", args = {} } },
                                                     otherwise = { { module = "b.js", args = {} } } } } }),
  translates('{"scripts":{"a":"node a.js && node b.js || node c.js && node d.js"}}',
             { version = "26.3.1", scripts = { a = {
               { attempt = { { module = "a.js", args = {} }, { module = "b.js", args = {} } },
                 otherwise = { { module = "c.js", args = {} } } },
               { module = "d.js", args = {} } } } }),
  translates([[{"scripts":{"a":"node a.js || echo ''"}}]],
             { version = "26.3.1", scripts = { a = { attempt = { { module = "a.js", args = {} } },
                                                     otherwise = { { echo = { "" } } } } } }),
  translates([[{"scripts":{"a":"sh -c 'node a.js \"$@\" && node b.js --x \"$@\"' sh"}}]],
             { version = "26.3.1", scripts = { a = {
               { module = "a.js", args = { { passed = true } } },
               { module = "b.js", args = { "--x", { passed = true } } } } } }),
  blocked('{"scripts":{"a":"echo -n x"}}', 'passes "-n" to echo'),
  blocked('{"scripts":{"a":"node a.js | node b.js"}}', "needs a shell"),
  blocked([[{"scripts":{"a":"sh -c 'node a.js; node b.js' sh"}}]], "needs a shell"),
  blocked([[{"scripts":{"a":"node a.js \"$@\""}}]], "needs a shell"),
  blocked('{"workspaces":["a"]}', "workspaces"),
  translates('{"overrides": {"a": {"b": "$b"}}}', { version = "26.3.1", overrides = '{"a": {"b": "$b"}}' }),
  blocked('{"overrides":["a"]}', "is not an object"),
  translates('{"peerDependencies":{"a":"1"},"peerDependenciesMeta":{"a":{"optional":true}}}',
             { version = "26.3.1", peerPackages = { a = "1" }, peerPackagesMeta = '{"a":{"optional":true}}' }),
  translates('{"optionalDependencies":{"a":"1"}}', { version = "26.3.1", optionalPackages = { a = "1" } }),
  blocked('{"peerDependenciesMeta":["a"]}', "is not an object"),
  blocked('{"peerDependencies":{"a":"github:u/a"}}', 'peerDependencies."a"'),
  blocked('{"bin":"cli.js"}', "bin"),
  translates('{"somethingNew":1}', { version = "26.3.1", packageFields = { somethingNew = "1" } }),
  translates('{ "browserslist" : ["> 1%", "x"] , "a":{"b":[1,{"c":"}]\\""}]}, "n": null}',
             { version = "26.3.1",
               packageFields = { browserslist = '["> 1%", "x"]', a = '{"b":[1,{"c":"}]\\""}]}', n = "null" } }),
  blocked('{"some\\u0041":1}', "escape"),
  blocked('{"engines":{"node":"<20"}}', "no pinned node"),
  blocked('{"main":"lib.js","scripts":{"start":"node app.js"}}', "main"),
  blocked('{"scripts":{"pretest":"node a.js","test":"node b.js"}}', "pretest"),
  blocked('{"scripts":{"prepublishOnly":"node a.js"}}', "prepublishOnly"),
  blocked('{"scripts":{"postinstall":"node a.js"}}', "postinstall"),
  blocked('{"scripts":{"clean":"cd dist && tsc"}}', "NPM-SURFACE.md"),
  blocked('{"scripts":{"Build":"node a.js","build":"node b.js"}}', "same daukle task"),
  blocked('{"scripts":{"run":"node a.js"}}', "lifecycle verb"),
  blocked('{"dependencies":{"a":"https://x.test/a.tgz?x=1"}}', "tarball"),
  blocked('{"dependencies":["a"]}', "dependencies"),
  blocked('{"dependencies":{"a":"file:./a"}}', "3. Dependencies: local paths, `file:`"),
  blocked('{"dependencies":{"a":"link:../a"}}', "local paths"),
  blocked('{"devDependencies":{"a":"./a"}}', "local paths"),
  blocked('{"devDependencies":{"a":"../a"}}', "local paths"),
  blocked('{"dependencies":{"a":"/abs/a"}}', "local paths"),
  blocked('{"dependencies":{"a":"~/a"}}', "local paths"),
  blocked('{"dependencies":{"a":"C:/a"}}', "local paths"),
  blocked('{"dependencies":{"a":"FILE:a"}}', "local paths"),
  blocked('{"dependencies":{"a":"vendor/a-1.0.0.tgz"}}', "local paths"),
  blocked('{"dependencies":{"a":"workspace:*"}}', "6. Workspaces: `workspaces`"),
  blocked('{"devDependencies":{"a":"workspace:^1.0.0"}}', "workspace protocol"),
  blocked('{"dependencies":{"a":"catalog:"}}', "6. Workspaces: `workspaces`"),
  blocked('{"devDependencies":{"a":"catalog:react18"}}', "catalog"),
  blocked('{"dependencies":{"a":"npm:workspace-tools@1"}}', 'is "npm:workspace-tools@1", an npm alias'),
  blocked('{"dependencies":{"b":"npm:catalog@2"}}', 'is "npm:catalog@2", an npm alias'),
  blocked('{"dependencies":{"a":"user/repo"}}', 'a GitHub "user/repo" shorthand'),
  blocked('{"dependencies":{"a":"user/repo#v1"}}', 'a GitHub "user/repo" shorthand'),
  blocked('{"dependencies":{"a":"github:user/repo"}}', "a git repository"),
  member_keeps('{"dependencies":{"a":"workspace:*"}}', "packages", "a", "workspace:*"),
  member_keeps('{"devDependencies":{"a":"workspace:^1.0.0"}}', "devPackages", "a", "workspace:^1.0.0"),
  member_keeps('{"dependencies":{"x":"catalog:"}}', "packages", "x", "catalog:"),
  member_keeps('{"dependencies":{"x":"catalog:legacy"}}', "packages", "x", "catalog:legacy"),
  member_keeps('{"dependencies":{"a":"file:../a"}}', "packages", "a", "file:../a"),
  member_blocked('{"dependencies":{"x":"file:../../outside"}}', "local paths"),
  member_blocked('{"dependencies":{"a":"link:../a"}}', "local paths"),
  member_blocked('{"dependencies":{"a":"../a"}}', "local paths"),
  member_blocked('{"dependencies":{"a":"npm:workspace-tools@1"}}', "an npm alias"),
  blocked('{"dependencies":{"a":"git+https://x.test/a.git"}}', "a git repository"),
  blocked('{"dependencies":{"a":"https://x.test/a.tgz"}}', "a url, which resolves outside the registry"),
  blocked('{"dependencies":{"a":"npm:@fumadocs/base-ui@16.15.4"}}', "3. Dependencies: dist-tags, git URLs"),
  translates('{"dependencies":{"a":"~1.2.3","b":"latest","c":">=1 <2 || 3.x"}}',
             { version = "26.3.1", packages = { a = "~1.2.3", b = "latest", c = ">=1 <2 || 3.x" } }),
  translates('{"name":"a","version":"1.0.0","exports":{"./sub":"./sub.js"}}',
             { version = "26.3.1", package = { name = '"a"', version = '"1.0.0"',
                                               exports = '{"./sub":"./sub.js"}' } }),
  blocked('{"exports":"./index.js"}', '"name" is missing or not a string'),
  translates('{"name":"a","version":"1.0.0","publishConfig":{"access":"public"}}',
             { version = "26.3.1", package = { name = '"a"', version = '"1.0.0"',
                                               publishConfig = '{"access":"public"}' } }),
  blocked('not json', "package.json"),
  blocked('{"engines":{"node":"^22","npm":">=11"}}', "engines.npm no pinned node that satisfies"),
  blocked('{"engines":{"npm":">=12"}}', "22.15.0 with npm 10.9.2"),
  blocked('{"engines":{"npm":"latest"}}', 'cannot read the engines.npm range "latest"'),
  blocked('{"engines":["node >= 0.8"]}', '"engines" is not a map'),
  blocked('{"dependencies":{"Not A Name":"1.0.0"}}', "is not an npm package name"),
  blocked('{"devDependencies":{"@scope":"1.0.0"}}', "is not an npm package name"),
  blocked('{"main":"../outside.js"}', "not a module inside the project"),
  blocked('{"main":"./"}', "not a module inside the project"),
  blocked('{"main":"C:/abs.js"}', "not a module inside the project"),
  blocked('{"type":"esm"}', "the project's own `\"type\"`"),
  resolves({ tsc = { provider("typescript", true) } },
           { bin = "typescript", binName = "tsc", args = { "-p", "." } }),
  resolves({ tsc = { provider("tsc", false) } }, { bin = "tsc", args = { "-p", "." } }),
  resolves({ tsc = { provider("tsc", true) } }, { bin = "tsc", args = { "-p", "." } }),
  resolves({ tsc = { provider("@scope/tsc", false) } }, { bin = "@scope/tsc", args = { "-p", "." } }),
  resolves({ tsc = { provider("@scope/tsc", true) } },
           { bin = "@scope/tsc", binName = "tsc", args = { "-p", "." } }),
  resolves_for_a_member({}, { tsc = { provider("typescript", true) } },
                        { bin = "typescript", binName = "tsc", args = { "-p", "." }, fromWorkspaceRoot = true }),
  resolves_for_a_member({ tsc = { provider("own", true) } }, { tsc = { provider("typescript", true) } },
                        { bin = "own", binName = "tsc", args = { "-p", "." } }),
  command_blocked({}, "no installed package provides"),
  command_blocked({ tsc = { provider("a", true), provider("b", false) } }, "both a and b"),
}
