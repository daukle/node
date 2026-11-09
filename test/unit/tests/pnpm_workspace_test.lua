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

local function renders(name, workspace, wanted)
  return { name = name, check = function() return expect.equal(pnpm_workspace.render(workspace), wanted) end }
end

local RENDERED = { members = { { dir = "packages/a" }, { dir = "packages/it's" } }, catalog = { react = "^18.2.0", ["@types/node"] = "20.0.0" },
                   catalogs = { legacy = { react = "^17.0.2" } } }

local function reads_back(field, wanted)
  return { name = "reads the rendered " .. field .. " back", check = function()
    return expect.equal(pnpm_workspace.read(pnpm_workspace.render(RENDERED))[field], wanted)
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
  reads("carries an unknown key and its nested and zero-indent lines", "hoistPattern:\n- a\nallowBuilds:\n  b: true\n",
        "carried", { "hoistPattern:", "- a", "allowBuilds:", "  b: true" }),
  reads("reads shadcn's packages past its unknown key", SHADCN, "packages", { "apps/*", "packages/*" }),
  reads("reads a block list at zero indent", "packages:\n- 'packages/*'\n- apps/*\n", "packages",
        { "packages/*", "apps/*" }),
  reads("skips a zero-indent list under an unknown key", "onlyBuiltDependencies:\n- esbuild\npackages:\n- a/*\n",
        "packages", { "a/*" }),
  reads("reads CRLF lines", "packages:\r\n  - 'packages/*'\r\ncatalog:\r\n  react: ^18.2.0\r\n", "catalog",
        { react = "^18.2.0" }),
  reads("reads past a byte order mark", "\239\187\191packages:\n  - 'packages/*'\n", "packages", { "packages/*" }),
  raises("refuses a bare glob ending in a colon", "packages:\n  - foo:\n", "  - foo:"),
  raises("refuses a bare glob holding a mapping", "packages:\n  - foo: bar\n", "  - foo: bar"),
  raises("refuses a catalog value holding a mapping", "catalog:\n  react: a: b\n", "  react: a: b"),
  { name = "lists a brace set, positive or negated", check = function()
    local workspace = pnpm_workspace.read("packages:\n  - '{apps,packages}/*'\n  - 'tools/*'\n  - '!tools/{a,b}'\n")
    return expect.equal(pnpm_workspace.brace_globs(workspace), { "{apps,packages}/*", "!tools/{a,b}" })
  end },
  raises("raises on a tab-indented line","packages:\n\t- 'packages/*'\n", "\t- 'packages/*'"),
  raises("raises on a list item under the catalog", "catalog:\n  - react\n", "  - react"),
  members("matches one segment for *", { "packages/*" }, {}, { "packages/a", "packages/a/b", "tools/c" },
          { "packages/a" }),
  members("matches any depth for **", { "apps/**" }, {}, { "apps/x/y", "apps/z", "lib/q" }, { "apps/x/y", "apps/z" }),
  members("lets an exclusion win", { "packages/*" }, { "packages/private" }, { "packages/a", "packages/private" },
          { "packages/a" }),
  members("reads a leading ./ and a trailing /", { "./packages/*/" }, {}, { "packages/a" }, { "packages/a" }),
  members("keeps a member nested in a member", { "packages/**" }, {}, { "packages/a", "packages/a/b" },
          { "packages/a", "packages/a/b" }),
  members("ignores pnpm's default directories", { "**" }, {},
          { "a", "x/node_modules/y", "x/bower_components/y", "x/test", "x/tests/y", "testing" }, { "a", "testing" }),
  members("does not match a dot directory with a wildcard", { "packages/*", "apps/**" }, {},
          { "packages/.hidden", "apps/.cache/x", "apps/web" }, { "apps/web" }),
  members("matches a dot directory named outright", { "packages/.config" }, {}, { "packages/.config" },
          { "packages/.config" }),
  members("sorts what it matches",{ "b/*", "a/*" }, {}, { "b/x", "a/y" }, { "a/y", "b/x" }),
  matches("packages/*", "packages/a", true),
  matches("packages/*", "packages/a/b", false),
  matches("**", "a/b/c", true),
  matches("apps/**/web", "apps/web", true),
  matches("apps/**/web", "apps/x/y/web", true),
  matches("apps/?b", "apps/ab", true),
  matches("**", "a/.b/c", false),
  matches("*", ".b", false),
  matches(".b/*", ".b/c", true),
  renders("renders each member and no catalog", { members = { { dir = "packages/a" }, { dir = "packages/b" } } },
          "packages:\n  - 'packages/a'\n  - 'packages/b'\n"),
  renders("renders no members as an empty list", { members = {} }, "packages: []\n"),
  { name = "reads no rendered members back", check = function()
    return expect.equal(pnpm_workspace.read(pnpm_workspace.render({ members = {} })).packages, {})
  end },
  renders("renders the catalogs sorted", RENDERED,
          "packages:\n  - 'packages/a'\n  - 'packages/it''s'\ncatalog:\n  '@types/node': '20.0.0'\n  'react': '^18.2.0'\n"
          .. "catalogs:\n  'legacy':\n    'react': '^17.0.2'\n"),
  renders("renders the settings after the catalogs as written",
          { members = {}, catalog = { a = "1" }, settings = "hoistPattern:\n- '*'\nminimumReleaseAge: 1 # day" },
          "packages: []\ncatalog:\n  'a': '1'\nhoistPattern:\n- '*'\nminimumReleaseAge: 1 # day\n"),
  raises("refuses a flow mapping with no space after its brace", "{packages: ['a/*']}\n", "is not a shape"),
  raises("refuses a value with a colon at the start of a line", "http://example.com\n", "is not a shape"),
  { name = "a catalog's name keeps its case", check = function()
    return expect.equal(pnpm_workspace.catalog_range({ catalogs = { Tools = { a = "1" } } }, "a", "catalog:Tools"), "1")
  end },
  { name = "the default catalog can be named in catalogs", check = function()
    return expect.equal(pnpm_workspace.catalog_range({ catalogs = { default = { a = "1" } } }, "a", "catalog:"), "1")
  end },
  { name = "a range that is no catalog has no catalog range", check = function()
    return expect.equal(pnpm_workspace.catalog_range({ catalog = { a = "1" } }, "a", "workspace:*"), nil)
  end },
  { name = "settings may hold settings", check = function()
    return expect.equal(pnpm_workspace.settings_problem("hoist: true\n"), nil)
  end },
  { name = "settings may not declare an empty packages list", check = function()
    return expect.contains(pnpm_workspace.settings_problem("packages: []\n"), "keys of their own")
  end },
  reads_back("packages", { "packages/a", "packages/it's" }),
  reads_back("catalog", { react = "^18.2.0", ["@types/node"] = "20.0.0" }),
  reads_back("catalogs", { legacy = { react = "^17.0.2" } }),
}
