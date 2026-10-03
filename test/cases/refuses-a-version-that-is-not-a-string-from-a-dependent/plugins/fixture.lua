--[[ Core refuses a non-string toolchains.node.version before the plugin sees
     it, so this guard is reachable only through the exported module, where the
     caller is another plugin rather than a manifest. See
     refuses-a-non-string-version for the manifest route. ]]
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

daukle.toolchain{
  name = "fixture",
  generate = function()
    runtimes.for_host{ os = "linux", arch = "x86_64", version = 22 }
    return { ["report.txt"] = "a number was accepted as a version after all" }
  end,
}
