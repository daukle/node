--[[ The url and sha256 below are never fetched: the manifest overrides this
     alias with a local path, which is the only way to require a plugin that
     has no release yet. Replace both with the real coordinate once daukle/node
     is published. ]]
daukle.plugin{
  api = 1,
  requires = {
    nbase = {
      url = "https://example.invalid/daukle-node/plugin.lua",
      sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
    },
  },
}

local runtimes = daukle.require("nbase:lib/runtimes")

local PINNED = { "22.15.0", "24.21.0", "26.3.1" }

local PUBLISHED = {
  { os = "linux", arch = "x86_64" },
  { os = "linux", arch = "aarch64" },
  { os = "macos", arch = "x86_64" },
  { os = "macos", arch = "aarch64" },
  { os = "windows", arch = "x86_64" },
  { os = "windows", arch = "aarch64" },
}

daukle.toolchain{
  name = "fixture",
  generate = function()
    local lines = {}
    for pinned = 1, #PINNED do
      for index = 1, #PUBLISHED do
        local host = PUBLISHED[index]
        local pick = runtimes.for_host{ os = host.os, arch = host.arch,
                                        version = PINNED[pinned] }
        lines[#lines + 1] = string.format("%s/%s %s %s %s %s %s", host.os, host.arch,
                                          pick.url, pick.sha256, pick.npm_version,
                                          pick.node, pick.npm)
      end
    end
    return { ["report.txt"] = table.concat(lines, "\n") .. "\n" }
  end,
}
