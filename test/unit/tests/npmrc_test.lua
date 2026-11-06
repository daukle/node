local npmrc = daukle.require("lib/npmrc")
local expect = daukle.require("tests/expect")

local function reads(text, wanted)
  return { name = "reads " .. text, check = function()
    local result = npmrc.read(text, ".npmrc")
    if #result.blockers > 0 then return "blocked: " .. result.blockers[1].construct end
    return expect.equal(result.config, wanted)
  end }
end

local function blocks(text, needle)
  return { name = "blocks " .. text, check = function()
    local result = npmrc.read(text, ".npmrc")
    if #result.blockers == 0 then return "wanted a blocker" end
    return expect.contains(result.blockers[1].construct .. " " .. result.blockers[1].why, needle)
  end }
end

return {
  reads("engine-strict=true\n", { ["engine-strict"] = "true" }),
  reads("auto-install-peers = true\r\nlockfile = true\r\n", { ["auto-install-peers"] = "true", lockfile = "true" }),
  reads("# a comment\n; another\n\nsave-exact\n", { ["save-exact"] = "true" }),
  reads('tag-version-prefix=""\n', { ["tag-version-prefix"] = "" }),
  reads("min-release-age=7 ; days\n", { ["min-release-age"] = "7" }),
  reads("init-author-name=a\\#b\n", { ["init-author-name"] = "a#b" }),
  reads("\239\187\191legacy-peer-deps=true", { ["legacy-peer-deps"] = "true" }),
  reads("", {}),
  blocks("omit[]=dev\n", "is a list"),
  blocks("[section]\nkey=value\n", "is an ini section"),
  { name = "names the environment npm reads", check = function()
    return expect.equal(npmrc.env({ ["legacy-peer-deps"] = "true" }), { npm_config_legacy_peer_deps = "true" })
  end },
}
