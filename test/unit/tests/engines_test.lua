local engines = daukle.require("lib/engines")
local expect = daukle.require("tests/expect")

local function picks(range, wanted)
  return { name = "picks " .. tostring(wanted) .. " for " .. tostring(range), check = function()
    return expect.equal((engines.newest_satisfying(range)), wanted)
  end }
end

local function refuses(range, needle)
  return { name = "refuses " .. range, check = function()
    local version, reason = engines.newest_satisfying(range)
    if version ~= nil then return "wanted a refusal, got " .. version end
    return expect.contains(reason, needle)
  end }
end

return {
  picks(nil, "26.3.1"),
  picks("*", "26.3.1"),
  picks(">=14", "26.3.1"),
  picks(">= 18.0.0", "26.3.1"),
  picks("^22", "22.15.0"),
  picks("^24.0.0 || ^22.0.0", "24.21.0"),
  picks("22.x", "22.15.0"),
  picks("~24.21", "24.21.0"),
  picks(">=20 <25", "24.21.0"),
  picks("22.0.0 - 24", "24.21.0"),
  picks("v26.3.1", "26.3.1"),
  picks("=22.15.0", "22.15.0"),
  picks("<=22.15", "22.15.0"),
  refuses("<20", "no pinned node satisfies"),
  refuses("^20.1.0", "no pinned node satisfies"),
  refuses("22.15.0-beta.1", "cannot read"),
  refuses(">=lts", "cannot read"),
  refuses("", "cannot read"),
  refuses("022", "cannot read"),
  refuses("22.015", "cannot read"),
}
