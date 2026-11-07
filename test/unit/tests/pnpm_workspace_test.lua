local pnpm_workspace = daukle.require("lib/pnpm_workspace")
local glob = daukle.require("lib/glob")
local expect = daukle.require("tests/expect")

local function reads(name, text, field, wanted)
  return { name = name, check = function() return expect.equal(pnpm_workspace.read(text)[field], wanted) end }
end

--- @implNote through `parse`, the value `read` raises, because the sandbox has no pcall.
local function raises(name, text, needle)
  return { name = name, check = function()
    local workspace, problem = pnpm_workspace.parse(text)
    if workspace ~= nil then return "wanted a problem" end
    return expect.contains(problem, needle)
  end }
end

local function members(name, packages, excluded, directories, wanted)
  return { name = name, check = function()
    return expect.equal(pnpm_workspace.members({ packages = packages, excluded = excluded }, directories), wanted)
  end }
end

local function matches(pattern, path, wanted)
  return { name = "glob.matches " .. pattern .. " " .. path, check = function()
    return expect.equal(glob.matches(pattern, path), wanted)
  end }
end

local SHADCN = "packages:\n  - \"apps/*\"\n  - \"packages/*\"\n\nallowBuilds:\n  esbuild: true\n"

return {
  reads("reads vue's packages", "packages:\n  - 'packages/*'\n", "packages", { "packages/*" }),
  reads("reads a flow list of packages", "packages: ['packages/*', \"apps/*\"]\n", "packages",
        { "packages/*", "apps/*" }),
  reads("reads a bare glob and skips comments", "# the members\npackages:\n  - packages/* # all\n\n", "packages",
        { "packages/*" }),
  reads("puts a negated glob in excluded", "packages:\n  - 'packages/*'\n  - '!packages/private'\n", "excluded",
        { "packages/private" }),
  reads("reads the catalog", "catalog:\n  react: ^18.2.0\n  '@types/node': \"20.0.0\"\n", "catalog",
        { react = "^18.2.0", ["@types/node"] = "20.0.0" }),
  reads("reads named catalogs", "catalogs:\n  react17:\n    react: ^17.0.2\n  react18:\n    react: ^18.2.0\n",
        "catalogs", { react17 = { react = "^17.0.2" }, react18 = { react = "^18.2.0" } }),
  reads("lists shadcn's allowBuilds as unknown", SHADCN, "unknown", { "allowBuilds" }),
  reads("reads shadcn's packages past its unknown key", SHADCN, "packages", { "apps/*", "packages/*" }),
  raises("raises on a tab-indented line", "packages:\n\t- 'packages/*'\n", "\t- 'packages/*'"),
  raises("raises on a list item under the catalog", "catalog:\n  - react\n", "  - react"),
  members("matches one segment for *", { "packages/*" }, {}, { "packages/a", "packages/a/b", "tools/c" },
          { "packages/a" }),
  members("matches any depth for **", { "apps/**" }, {}, { "apps/x/y", "apps/z", "lib/q" }, { "apps/x/y", "apps/z" }),
  members("lets an exclusion win", { "packages/*" }, { "packages/private" }, { "packages/a", "packages/private" },
          { "packages/a" }),
  members("reads a leading ./ and a trailing /", { "./packages/*/" }, {}, { "packages/a" }, { "packages/a" }),
  members("sorts what it matches", { "b/*", "a/*" }, {}, { "b/x", "a/y" }, { "a/y", "b/x" }),
  matches("packages/*", "packages/a", true),
  matches("packages/*", "packages/a/b", false),
  matches("**", "a/b/c", true),
  matches("apps/**/web", "apps/web", true),
  matches("apps/**/web", "apps/x/y/web", true),
  matches("apps/?b", "apps/ab", true),
}
