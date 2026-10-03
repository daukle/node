--[[ The raise is the assertion, because the plugin sandbox has no pcall: a
     chunk cannot catch an error, so the only way to observe a refusal is to
     let it end the sync. See the-table-answers-every-published-row for why the
     url below is never fetched. ]]
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
    runtimes.for_host{ os = "plan9", arch = "x86_64", version = "22.15.0" }
    return { ["report.txt"] = "nodejs.org publishes a plan9 build after all\n" }
  end,
}
