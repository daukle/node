local links = daukle.require("lib/links")

local SCRIPT_NAME = "__daukle_pack__.mjs"
local MANIFEST_NAME = "pack-package.json"
local RESOLVED_MANIFEST_NAME = "pack-package-resolved.json"
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
import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { delimiter, dirname, join, relative, resolve } from "node:path";

const [mode, npmCli, ...rest] = process.argv.slice(2);

function withNodeOnPath() {
  return { ...process.env, PATH: dirname(process.execPath) + delimiter + (process.env.PATH ?? "") };
}

function npm(directory, destination, args, capture) {
  const result = spawnSync(process.execPath, [npmCli, ...args, "--cache", join(destination, "npm-cache-pack")],
    { cwd: directory, encoding: "utf8", stdio: ["ignore", capture ? "pipe" : "inherit", "inherit"],
      env: withNodeOnPath() });
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

/** Whether a path lies in a derived directory daukle made, which a `files` entry naming the
 *  directory around it would otherwise ship. */
function isDerived(path) {
  return `/${path}`.includes("/build/daukle/");
}

/** Copies a project's files, skipping what npm never packs from and daukle's own build directory,
 *  which holds the destination: Node's cpSync refuses a copy into its own subdirectory. */
function copyTree(source, target, path) {
  mkdirSync(target, { recursive: true });
  for (const entry of readdirSync(source, { withFileTypes: true })) {
    const child = path === "" ? entry.name : `${path}/${entry.name}`;
    if (NOT_COPIED.has(entry.name) || isDerived(`${child}/`)) continue;
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

/** The tarball without what `isDerived` names: pnpm has no way to leave a path out of a pack. */
async function withoutDerived(tarball, stageDirectory) {
  const tar = createRequire(join(dirname(dirname(npmCli)), "package.json"))("tar");
  rmSync(stageDirectory, { recursive: true, force: true });
  mkdirSync(stageDirectory, { recursive: true });
  await tar.x({ file: tarball, cwd: stageDirectory, filter: (path) => !isDerived(path) });
  await tar.c({ gzip: true, file: tarball, cwd: stageDirectory }, ["package"]);
  return tarball;
}

/** @implNote a junction only where Windows refuses a symlink: a relative symlink reached through a
 *  junction resolves against the junction's location, and pnpm 12 writes relative ones. */
function linkDirectory(target, link) {
  try {
    symlinkSync(target, link, "dir");
  } catch (error) {
    if (error.code !== "EPERM") throw error;
    symlinkSync(target, link, "junction");
  }
}

/** Runs pnpm's pack with `node_modules` in place, where pnpm alone looks for a workspace sibling's
 *  version: the proof installs elsewhere so that it writes nothing into the author's tree. */
function runPnpmPack(pnpmEntry, modules, directory, destination) {
  const link = join(directory, "node_modules");
  const linked = !existsSync(link);
  if (linked) linkDirectory(modules, link);
  try {
    return spawnSync(process.execPath, [pnpmEntry, "pack", "--pack-destination", destination],
      { cwd: directory, stdio: ["ignore", "inherit", "inherit"], env: withNodeOnPath() });
  } finally {
    if (linked) rmSync(link, { force: true });
  }
}

/** A workspace package as pnpm packs it, which resolves the ranges npm would leave as written. */
async function packWithPnpm(pnpmEntry, modules, directory, destination) {
  for (const name of tarballs(destination)) rmSync(join(destination, name));
  const result = runPnpmPack(pnpmEntry, modules, directory, destination);
  if (result.status !== 0) throw new Error(`pnpm pack exited with code ${result.status}`);
  const made = [...tarballs(destination)];
  if (made.length !== 1) throw new Error(`pnpm pack left ${made.length} tarballs in ${destination}`);
  return withoutDerived(join(destination, made[0]), join(destination, "pnpm-pack"));
}

/** A workspace package as its own pnpm packs it with its scripts: the whole workspace copied and
 *  installed, since `pnpm install` and `pnpm pack` each run `prepare` and it reads its dependencies. */
async function packWorkspaceWithScripts(pnpmEntry, workspaceRoot, directory, destination) {
  const copy = join(destination, "project");
  rmSync(copy, { recursive: true, force: true });
  copyTree(workspaceRoot, copy, "");
  const install = spawnSync(process.execPath, [pnpmEntry, "install", "--frozen-lockfile",
    "--config.confirmModulesPurge=false", "--store-dir", join(destination, "pnpm-store-pack")],
    { cwd: copy, stdio: ["ignore", "inherit", "inherit"], env: withNodeOnPath() });
  if (install.status !== 0) throw new Error(`pnpm install exited with code ${install.status}`);
  const packageCopy = join(copy, relative(workspaceRoot, directory));
  return packWithPnpm(pnpmEntry, join(packageCopy, "node_modules"), packageCopy, destination);
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

const LICENSE_FILE = /^LICEN[CS]E(\..+)?$/i;

/** The workspace root's license files, which `pnpm pack` adds to a member that ships none. */
function inheritedLicenses(workspaceRoot, files) {
  if (workspaceRoot === undefined || files.some((file) => LICENSE_FILE.test(file))) return [];
  return readdirSync(workspaceRoot, { withFileTypes: true })
    .filter((entry) => entry.isFile() && LICENSE_FILE.test(entry.name))
    .map((entry) => entry.name);
}

async function stage(root, manifestPath, stageDirectory, destination, workspaceRoot) {
  if (!existsSync(join(root, "package.json"))) process.exit(]==] .. NO_ROOT_MANIFEST .. [==[);
  const npm = createRequire(join(dirname(dirname(npmCli)), "package.json"));
  const Arborist = npm("@npmcli/arborist");
  const packlist = npm("npm-packlist");
  const manifestText = readFileSync(manifestPath, "utf8");
  const tree = await new Arborist({ path: root }).loadActual();
  tree.package = JSON.parse(manifestText);
  const files = await packlist(tree, { path: root });
  rmSync(stageDirectory, { recursive: true, force: true });
  mkdirSync(stageDirectory, { recursive: true });
  for (const file of files) {
    if (file === "package.json" || DAUKLE_ROOT_ENTRIES.has(file.split("/")[0]) || isDerived(file)) continue;
    mkdirSync(dirname(join(stageDirectory, file)), { recursive: true });
    stageFile(join(root, file), join(stageDirectory, file), file);
  }
  for (const license of inheritedLicenses(workspaceRoot, files)) copyFileSync(join(workspaceRoot, license), join(stageDirectory, license));
  writeFileSync(join(stageDirectory, "package.json"), manifestText);
  record(pack(stageDirectory, destination), destination);
}

if (mode === "stage") {
  const [root, manifestPath, stageDirectory, destination, workspaceRoot] = rest.map((path) => resolve(path));
  await stage(root, manifestPath, stageDirectory, destination, workspaceRoot);
} else if (mode === "with-pnpm") {
  const [pnpmEntry, modules, directory, destination] = rest.map((path) => resolve(path));
  record(await packWithPnpm(pnpmEntry, modules, directory, destination), destination);
} else if (mode === "with-pnpm-scripts") {
  const [pnpmEntry, workspaceRoot, directory, destination] = rest.map((path) => resolve(path));
  record(await packWorkspaceWithScripts(pnpmEntry, workspaceRoot, directory, destination), destination);
} else if (mode === "copy-sources") {
  const [source, target] = rest.map((path) => resolve(path));
  rmSync(target, { recursive: true, force: true });
  copyTree(source, target, "");
} else if (mode === "link-modules") {
  const [target, link] = rest.map((path) => resolve(path));
  rmSync(link, { recursive: true, force: true });
  linkDirectory(target, link);
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
         RESOLVED_MANIFEST_NAME = RESOLVED_MANIFEST_NAME,
         TARBALL_NAME = TARBALL_NAME, STAGE_DIR = STAGE_DIR, NO_ROOT_MANIFEST = NO_ROOT_MANIFEST }
