local SCRIPT_NAME = "__daukle_tree__.mjs"
local OUTPUT_NAME = "dependency-tree.txt"

--[[ @implNote dot entries are skipped because npm keeps its own bookkeeping
     there (.bin, .package-lock.json), which differs between an npm ci and an
     npm install of the same tree; pnpm's .pnpm is read apart, by its entries.

     `--modules <dir>` names the node_modules to read, and `--workspace <dir>` the pnpm workspace
     root it belongs to. In a workspace a link to one of its projects is listed by the project's
     path, since a project's package.json is the migration's own rendering of it, and only the
     store entries this node_modules reaches are listed, since the store is the whole
     workspace's. ]]
local SCRIPT = [==[
import { existsSync, readdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { basename, dirname, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

const here = dirname(fileURLToPath(import.meta.url));
const { values } = parseArgs({ options: { modules: { type: "string" }, workspace: { type: "string" } } });
const modules = values.modules === undefined ? join(here, "node_modules") : resolve(values.modules);
const workspace = values.workspace === undefined ? undefined : realpathSync(resolve(values.workspace));
const lines = [];
const reached = new Set();

/** The workspace project a real path is, as its path from the workspace root, or undefined. */
function projectOf(real) {
  const path = relative(workspace, real).split(sep).join("/");
  if (path.startsWith("..") || path.split("/").includes("node_modules")) return undefined;
  return path === "" ? "." : path;
}

/** The virtual store directory of the package installed at `real` under `name`. */
function storeEntryOf(real, name) {
  const modulesDirectory = name.startsWith("@") ? dirname(dirname(real)) : dirname(real);
  return dirname(modulesDirectory);
}

/** A virtual store entry and every entry its dependencies, its siblings there, reach. */
function reach(entry) {
  if (reached.has(entry)) return;
  reached.add(entry);
  eachPackage(join(entry, "node_modules"), (directory, name) => {
    const real = realpathSync(directory);
    if (projectOf(real) === undefined) reach(storeEntryOf(real, name));
  });
}

/** @implNote a `file:` directory inside the workspace is installed as a copy in the store, whose
 *  package.json is the project's own rendering, so it is listed by its store id instead. */
function visit(directory, path, name) {
  if (workspace !== undefined) {
    const real = realpathSync(directory);
    const project = projectOf(real);
    if (project !== undefined) {
      lines.push(`${path} link:${project}`);
      return;
    }
    const entry = storeEntryOf(real, name);
    reach(entry);
    if (basename(entry).includes("@file+")) {
      lines.push(`${path} ${basename(entry)}`);
      return;
    }
  }
  let manifest;
  try {
    manifest = JSON.parse(readFileSync(join(directory, "package.json"), "utf8"));
  } catch (error) {
    throw new Error(`${path} is an installed package whose package.json cannot be read: ${error.message}`);
  }
  lines.push(`${path} ${manifest.name}@${manifest.version}`);
  walk(join(directory, "node_modules"), path + "/node_modules/");
}

function packageEntries(directory) {
  return readdirSync(directory, { withFileTypes: true })
    .filter((entry) => !entry.name.startsWith("."))
    .filter((entry) => entry.isDirectory() || entry.isSymbolicLink());
}

function eachPackage(modulesDirectory, visitPackage) {
  if (!existsSync(modulesDirectory)) return;
  for (const entry of packageEntries(modulesDirectory)) {
    if (entry.name.startsWith("@")) {
      for (const scoped of packageEntries(join(modulesDirectory, entry.name))) {
        visitPackage(join(modulesDirectory, entry.name, scoped.name), entry.name + "/" + scoped.name);
      }
      continue;
    }
    visitPackage(join(modulesDirectory, entry.name), entry.name);
  }
}

function walk(modulesDirectory, prefix) {
  eachPackage(modulesDirectory, (directory, name) => visit(directory, prefix + name, name));
}

/** pnpm's virtual store, one directory per installed package id: a package's own dependencies are
 *  its siblings there rather than below it, so the walk above reaches only the direct ones. */
function virtualStore(modulesDirectory) {
  const store = join(modulesDirectory, ".pnpm");
  if (!existsSync(store)) return;
  for (const entry of readdirSync(store, { withFileTypes: true })) {
    if (entry.isDirectory() && entry.name !== "node_modules") lines.push(`.pnpm ${entry.name}`);
  }
}

walk(modules, "");
if (workspace === undefined) virtualStore(modules);
for (const entry of reached) lines.push(`.pnpm ${basename(entry)}`);
lines.sort();
const text = lines.join("\n") + "\n";
writeFileSync(join(here, "]==] .. OUTPUT_NAME .. [==["), text);
process.stdout.write(text);
]==]

return { SCRIPT_NAME = SCRIPT_NAME, SCRIPT = SCRIPT, OUTPUT_NAME = OUTPUT_NAME }
