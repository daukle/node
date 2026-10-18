local npm_errors = daukle.require("lib/npm_errors")
local expect = daukle.require("tests/expect")

local ETARGET = [==[
npm error code ETARGET
npm error notarget No matching version found for semver@999.0.0.
npm error notarget In most cases you or one of your dependencies are requesting a package version that doesn't exist.
npm error A complete log of this run can be found in: C:\Users\x\AppData\Local\npm-cache\_logs\2026-10-18T16_06_26_492Z-debug-0.log
]==]

local ERESOLVE = [==[
npm error code ERESOLVE
npm error ERESOLVE unable to resolve dependency tree
npm error
npm error While resolving: daukle-migrate-probe@0.0.0
npm error Found: react@17.0.2
npm error node_modules/react
npm error   react@"17.0.2" from the root project
npm error
npm error Could not resolve dependency:
npm error peer react@"^18.2.0" from react-dom@18.2.0
npm error node_modules/react-dom
npm error   react-dom@"18.2.0" from the root project
npm error
npm error Fix the upstream dependency conflict, or retry this command with --force or --legacy-peer-deps to accept an incorrect (and potentially broken) dependency resolution.
npm error
npm error
npm error For a full report see:
npm error C:\Users\x\AppData\Local\npm-cache\_logs\2026-10-18T16_23_32_220Z-eresolve-report.txt
npm error A complete log of this run can be found in: C:\Users\x\AppData\Local\npm-cache\_logs\2026-10-18T16_23_32_220Z-debug-0.log
]==]

local ECONNREFUSED = [==[
npm error code ECONNREFUSED
npm error syscall connect
npm error errno ECONNREFUSED
npm error FetchError: request to http://127.0.0.1:9/semver failed, reason: connect ECONNREFUSED 127.0.0.1:9
npm error     at ClientRequest.<anonymous> (C:\npm\node_modules\minipass-fetch\lib\index.js:130:14)
npm error   code: 'ECONNREFUSED',
npm error }
npm error
npm error If you are behind a proxy, please make sure that the 'proxy' config is set properly.  See: 'npm help config'
npm error A complete log of this run can be found in: C:\Users\x\AppData\Local\npm-cache\_logs\2026-10-18T16_23_52_256Z-debug-0.log
]==]

local NO_CODE = "npm error something went wrong\nnpm error A complete log of this run can be found in: /tmp/x.log\n"

local function classified(name, stderr, wanted_resolution, needles)
  return { name = "classifies " .. name, check = function()
    local install = npm_errors.of_install(stderr, 1)
    if install.resolution ~= wanted_resolution then
      return "wanted resolution " .. tostring(wanted_resolution) .. ", got " .. install.message
    end
    for _, needle in ipairs(needles) do
      local problem = expect.contains(install.message, needle)
      if problem ~= nil then return problem end
    end
    return nil
  end }
end

local function lacks(name, stderr, needle)
  return { name = name .. " leaves out " .. needle, check = function()
    local message = npm_errors.of_install(stderr, 1).message
    if string.find(message, needle, 1, true) then return "message holds " .. needle .. ": " .. message end
    return nil
  end }
end

return {
  classified("ETARGET", ETARGET, true, { "No matching version found for semver@999.0.0.",
                                         "A complete log of this run can be found in: C:\\Users" }),
  classified("ETARGET with CRLF", string.gsub(ETARGET, "\n", "\r\n"), true,
             { "semver@999.0.0.; notarget In most cases" }),
  classified("ERESOLVE", ERESOLVE, true, { "Could not resolve dependency",
                                           'peer react@"^18.2.0" from react-dom@18.2.0',
                                           "debug-0.log" }),
  classified("ECONNREFUSED", ECONNREFUSED, false, { "connect ECONNREFUSED 127.0.0.1:9", "debug-0.log" }),
  classified("a failure with no code line", NO_CODE, false, { "something went wrong" }),
  classified("a failure with no npm error line", "", false, { "npm exited with code 1" }),
  lacks("ETARGET", ETARGET, "code ETARGET"),
  lacks("ERESOLVE", ERESOLVE, "Fix the upstream"),
  lacks("ECONNREFUSED", ECONNREFUSED, "errno"),
}
