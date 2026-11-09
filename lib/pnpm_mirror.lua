--- The loopback registry `node:install` runs pnpm against for a pnpm project: it serves only the
--- tarballs daukle fetched by sha256, so pnpm installs the pinned closure with no other network
--- (D-251, spec section 1, M5). pnpm verifies each tarball's integrity itself.
local SCRIPT_NAME = "__daukle_pnpm_mirror__.mjs"
local MAP_NAME = "pnpm-mirror.json"

--[[ @implNote the lockfile is left untouched and the registry moved instead: pnpm 10 refuses a
     lockfile entry whose registry-style path is backed by a file, and files a tarball added with
     `pnpm store add` under its path rather than its integrity, so an offline install misses it.
     A path is compared decoded, since a client may send a scoped name's "/" as "%2f". ]]
local SCRIPT = [==[
import { createReadStream } from "node:fs";
import { readFileSync } from "node:fs";
import { createServer } from "node:http";
import { spawn } from "node:child_process";
import { delimiter, dirname } from "node:path";

const [mapPath, pnpmCli, ...args] = process.argv.slice(2);
const decoded = (path) => decodeURIComponent(path.split("?")[0]).toLowerCase();
const files = new Map(Object.entries(JSON.parse(readFileSync(mapPath, "utf8"))).map(([path, file]) => [decoded(path), file]));

const server = createServer((request, response) => {
  const file = files.get(decoded(request.url));
  if (file === undefined) {
    response.writeHead(404);
    response.end();
    return;
  }
  response.writeHead(200, { "content-type": "application/octet-stream" });
  createReadStream(file).pipe(response);
});

server.listen(0, "127.0.0.1", () => {
  const registry = `http://127.0.0.1:${server.address().port}/`;
  const env = { ...process.env, PATH: dirname(process.execPath) + delimiter + (process.env.PATH ?? "") };
  const command = pnpmCli.endsWith(".cjs") ? [process.execPath, pnpmCli] : [pnpmCli];
  const child = spawn(command[0], [...command.slice(1), ...args, "--registry", registry], { stdio: "inherit", env });
  child.on("exit", (code, signal) => {
    server.close();
    process.exit(code ?? (signal ? 1 : 0));
  });
});
]==]

local function json_string(text)
  return '"' .. string.gsub(text, '[%c"\\]', function(character)
    if character == '"' then return '\\"' end
    if character == "\\" then return "\\\\" end
    return string.format("\\u%04x", string.byte(character))
  end) .. '"'
end

--- The url path pnpm asks the mirror for, which is the pinned url's path on the registry.
local function url_path(url)
  return string.match(url, "^https?://[^/]+(/.*)$") or url
end

--- The map file's text: each pinned url's path to the file daukle fetched for it.
local function map_json(fetched)
  local members = {}
  for index, item in ipairs(fetched) do
    members[index] = "  " .. json_string(url_path(item.url)) .. ": " .. json_string(item.file)
  end
  return "{\n" .. table.concat(members, ",\n") .. "\n}\n"
end

return { SCRIPT_NAME = SCRIPT_NAME, SCRIPT = SCRIPT, MAP_NAME = MAP_NAME, map_json = map_json }
