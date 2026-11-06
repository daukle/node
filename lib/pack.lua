local links = daukle.require("lib/links")

local SCRIPT_NAME = "__daukle_pack__.mjs"
local MANIFEST_NAME = "pack-package.json"
local TARBALL_NAME = "package.tgz"
local STAGE_DIR = "pack"

--- Exit code of `stage` when the package root holds no package.json: npm-packlist applies a
--- manifest's `files` and `main` only on finding that file, so node:pack installs first.
local NO_ROOT_MANIFEST = 3

--[[ @implNote the file list is npm-packlist's own, from the provisioned npm, with the
     tree's manifest replaced in memory; a list re-derived here would be a second
     packlist that disagrees with it at its edges. ]]
local SCRIPT = [==[
import { spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { delimiter, dirname, join, resolve } from "node:path";

const [mode, npmCli, ...rest] = process.argv.slice(2);

function npm(directory, destination, args, capture) {
  const result = spawnSync(process.execPath, [npmCli, ...args, "--cache", join(destination, "npm-cache-pack")],
    { cwd: directory, encoding: "utf8", stdio: ["ignore", capture ? "pipe" : "inherit", "inherit"],
      env: { ...process.env, PATH: dirname(process.execPath) + delimiter + (process.env.PATH ?? "") } });
  if (result.status !== 0) throw new Error(`npm ${args[0]} exited with code ${result.status}`);
  return result.stdout;
}

function tarballs(destination) {
  return new Set(readdirSync(destination).filter((name) => name.endsWith(".tgz")));
}

/** Packs and returns the tarball that appeared, rather than parsing npm's output: a script's own
 *  output shares stdout and may end without a newline, as husky's ".git can't be found" does. */
function pack(directory, destination, scripts = false) {
  const flags = scripts ? [] : ["--ignore-scripts"];
  for (const name of tarballs(destination)) rmSync(join(destination, name));
  npm(directory, destination, ["pack", ...flags, "--pack-destination", destination], false);
  const made = [...tarballs(destination)];
  if (made.length !== 1) throw new Error(`npm pack left ${made.length} tarballs in ${destination}`);
  return join(destination, made[0]);
}

const NOT_COPIED = new Set([".git", "node_modules"]);

/** The root entries daukle itself writes, which configure the build and are not the package's
 *  content: a migrated package packs what it packed before migrating. */
const DAUKLE_ROOT_ENTRIES = new Set(["daukle.toml", "daukle.lua", "daukle", "daukle.ps1"]);

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

/** Keeps the tarball under one name on both sides of the proof, whatever npm named it. */
function record(tarball, destination) {
  copyFileSync(tarball, join(destination, "]==] .. TARBALL_NAME .. [==["));
  process.stdout.write(`${tarball}\n`);
}

const MARKER_KEY = "]==] .. links.MARKER_KEY .. [==[";
const MARKER_TEXT = "]==] .. links.MARKER_TEXT .. [==[";

/** A nested package.json node:install placed, without the marker that says so: the package ships
 *  the file it declared, which a migrated package's proof compares by value. */
function stageFile(source, target, file) {
  if (file.endsWith("/package.json")) {
    const text = readFileSync(source, "utf8");
    const manifest = JSON.parse(text);
    if (Object.keys(manifest)[0] === MARKER_KEY && manifest[MARKER_KEY] === MARKER_TEXT) {
      delete manifest[MARKER_KEY];
      writeFileSync(target, JSON.stringify(manifest, null, 2) + "\n");
      return;
    }
  }
  copyFileSync(source, target);
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
    if (file === "package.json" || DAUKLE_ROOT_ENTRIES.has(file.split("/")[0])) continue;
    mkdirSync(dirname(join(stageDirectory, file)), { recursive: true });
    stageFile(join(root, file), join(stageDirectory, file), file);
  }
  writeFileSync(join(stageDirectory, "package.json"), manifestText);
  record(pack(stageDirectory, destination), destination);
}

if (mode === "stage") {
  const [root, manifestPath, stageDirectory, destination] = rest.map((path) => resolve(path));
  await stage(root, manifestPath, stageDirectory, destination);
} else if (mode === "in-place") {
  const [directory, destination] = rest.map((path) => resolve(path));
  record(pack(directory, destination), destination);
} else if (mode === "with-scripts") {
  const [directory, destination] = rest.map((path) => resolve(path));
  record(packWithScripts(directory, destination), destination);
} else {
  throw new Error(`unknown mode ${mode}`);
}
]==]

return { SCRIPT_NAME = SCRIPT_NAME, SCRIPT = SCRIPT, MANIFEST_NAME = MANIFEST_NAME,
         TARBALL_NAME = TARBALL_NAME, STAGE_DIR = STAGE_DIR, NO_ROOT_MANIFEST = NO_ROOT_MANIFEST }
