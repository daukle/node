local SCRIPT_NAME = "__daukle_pack__.mjs"
local MANIFEST_NAME = "pack-package.json"
local LISTING_NAME = "pack-listing.txt"
local STAGE_DIR = "pack"

--- Exit code of `stage` when the package root holds no package.json: npm-packlist applies a
--- manifest's `files` and `main` only on finding that file, so node:pack installs first.
local NO_ROOT_MANIFEST = 3

--[[ @implNote the file list is npm-packlist's own, from the provisioned npm, with the
     tree's manifest replaced in memory; a list re-derived here would be a second
     packlist that disagrees with it at its edges. The listing hashes package.json
     over canonical JSON because the packed manifest is rendered, not the author's
     bytes (ruling 5.1), and every other member by its bytes. ]]
local SCRIPT = [==[
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { delimiter, dirname, join, resolve } from "node:path";
import { gunzipSync } from "node:zlib";

const [mode, npmCli, ...rest] = process.argv.slice(2);

function npm(directory, destination, args, capture) {
  const result = spawnSync(process.execPath, [npmCli, ...args, "--cache", join(destination, "npm-cache-pack")],
    { cwd: directory, encoding: "utf8", stdio: ["ignore", capture ? "pipe" : "inherit", "inherit"],
      env: { ...process.env, PATH: dirname(process.execPath) + delimiter + (process.env.PATH ?? "") } });
  if (result.status !== 0) throw new Error(`npm ${args[0]} exited with code ${result.status}`);
  return result.stdout;
}

function pack(directory, destination, scripts = false) {
  const flags = scripts ? [] : ["--ignore-scripts"];
  const stdout = npm(directory, destination, ["pack", ...flags, "--json", "--pack-destination", destination], true);
  return join(destination, JSON.parse(stdout)[0].filename);
}

const NOT_COPIED = new Set([".git", "node_modules"]);

/** Copies a project's files, skipping what npm never packs from and daukle's own build directory,
 *  which holds the destination: Node's cpSync refuses a copy into its own subdirectory. */
function copyTree(source, target, path) {
  mkdirSync(target, { recursive: true });
  for (const entry of readdirSync(source, { withFileTypes: true })) {
    const child = path === "" ? entry.name : `${path}/${entry.name}`;
    if (NOT_COPIED.has(entry.name) || child === "build/daukle") continue;
    if (entry.isDirectory()) copyTree(join(source, entry.name), join(target, entry.name), child);
    else if (entry.isFile()) copyFileSync(join(source, entry.name), join(target, entry.name));
  }
}

/** The original project as npm would pack it with its scripts: a copy, installed, then packed. */
function packWithScripts(directory, destination) {
  const copy = join(destination, "project");
  rmSync(copy, { recursive: true, force: true });
  copyTree(directory, copy, "");
  npm(copy, destination, [existsSync(join(copy, "package-lock.json")) ? "ci" : "install", "--no-audit", "--no-fund"], false);
  return pack(copy, destination, true);
}

function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value === null || typeof value !== "object") return value;
  return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonical(value[key])]));
}

function octal(block, start, length) {
  return parseInt(block.toString("latin1", start, start + length).replace(/\0.*$/s, "").trim() || "0", 8);
}

function text(block, start, length) {
  return block.toString("utf8", start, start + length).replace(/\0.*$/s, "");
}

function paxPath(body) {
  for (const record of body.toString("utf8").split("\n")) {
    const match = /^\d+ path=(.*)$/s.exec(record);
    if (match) return match[1];
  }
  return null;
}

function members(tarball) {
  const bytes = gunzipSync(readFileSync(tarball));
  const out = [];
  let offset = 0;
  let longPath = null;
  while (offset + 512 <= bytes.length) {
    const header = bytes.subarray(offset, offset + 512);
    if (header.every((byte) => byte === 0)) break;
    const size = octal(header, 124, 12);
    const type = String.fromCharCode(header[156] || 48);
    const body = bytes.subarray(offset + 512, offset + 512 + size);
    offset += 512 + Math.ceil(size / 512) * 512;
    if (type === "x") { longPath = paxPath(body); continue; }
    const prefix = text(header, 345, 155);
    const name = longPath ?? (prefix ? `${prefix}/${text(header, 0, 100)}` : text(header, 0, 100));
    longPath = null;
    if (type === "0" || type === "\0") out.push({ name, body });
  }
  return out;
}

function listing(tarball, destination) {
  const lines = members(tarball).map(({ name, body }) => {
    const digested = name === "package/package.json"
      ? "json:" + createHash("sha256").update(JSON.stringify(canonical(JSON.parse(body.toString("utf8"))))).digest("hex")
      : createHash("sha256").update(body).digest("hex");
    return `${name} ${digested}`;
  }).sort();
  const text = lines.join("\n") + "\n";
  writeFileSync(join(destination, "]==] .. LISTING_NAME .. [==["), text);
  process.stdout.write(`${tarball}\n${text}`);
}

async function stage(root, manifestPath, stageDirectory, destination) {
  if (!existsSync(join(root, "package.json"))) process.exit(]==] .. NO_ROOT_MANIFEST .. [==[);
  const npm = createRequire(join(dirname(dirname(npmCli)), "package.json"));
  const Arborist = npm("@npmcli/arborist");
  const packlist = npm("npm-packlist");
  const manifestText = readFileSync(manifestPath, "utf8");
  const tree = await new Arborist({ path: root }).loadActual();
  tree.package = JSON.parse(manifestText);
  const files = await packlist(tree, { path: root });
  rmSync(stageDirectory, { recursive: true, force: true });
  for (const file of files) {
    if (file === "package.json") continue;
    mkdirSync(dirname(join(stageDirectory, file)), { recursive: true });
    copyFileSync(join(root, file), join(stageDirectory, file));
  }
  writeFileSync(join(stageDirectory, "package.json"), manifestText);
  listing(pack(stageDirectory, destination), destination);
}

if (mode === "stage") {
  const [root, manifestPath, stageDirectory, destination] = rest.map((path) => resolve(path));
  await stage(root, manifestPath, stageDirectory, destination);
} else if (mode === "in-place") {
  const [directory, destination] = rest.map((path) => resolve(path));
  listing(pack(directory, destination), destination);
} else if (mode === "with-scripts") {
  const [directory, destination] = rest.map((path) => resolve(path));
  listing(packWithScripts(directory, destination), destination);
} else {
  throw new Error(`unknown mode ${mode}`);
}
]==]

return { SCRIPT_NAME = SCRIPT_NAME, SCRIPT = SCRIPT, MANIFEST_NAME = MANIFEST_NAME,
         LISTING_NAME = LISTING_NAME, STAGE_DIR = STAGE_DIR, NO_ROOT_MANIFEST = NO_ROOT_MANIFEST }
