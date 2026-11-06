local SCRIPT_NAME = "__daukle_tree__.mjs"
local OUTPUT_NAME = "dependency-tree.txt"

--[[ @implNote dot entries are skipped because npm keeps its own bookkeeping
     there (.bin, .package-lock.json), which differs between an npm ci and an
     npm install of the same tree; pnpm's .pnpm is read apart, by its entries. ]]
local SCRIPT = [==[
import { existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const lines = [];

function visit(directory, path) {
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

function walk(modules, prefix) {
  if (!existsSync(modules)) return;
  for (const entry of packageEntries(modules)) {
    if (entry.name.startsWith("@")) {
      for (const scoped of packageEntries(join(modules, entry.name))) {
        visit(join(modules, entry.name, scoped.name), prefix + entry.name + "/" + scoped.name);
      }
      continue;
    }
    visit(join(modules, entry.name), prefix + entry.name);
  }
}

/** pnpm's virtual store, one directory per installed package id: a package's own dependencies are
 *  its siblings there rather than below it, so the walk above reaches only the direct ones. */
function virtualStore(modules) {
  const store = join(modules, ".pnpm");
  if (!existsSync(store)) return;
  for (const entry of readdirSync(store, { withFileTypes: true })) {
    if (entry.isDirectory() && entry.name !== "node_modules") lines.push(`.pnpm ${entry.name}`);
  }
}

walk(join(here, "node_modules"), "");
virtualStore(join(here, "node_modules"));
lines.sort();
const text = lines.join("\n") + "\n";
writeFileSync(join(here, "]==] .. OUTPUT_NAME .. [==["), text);
process.stdout.write(text);
]==]

return { SCRIPT_NAME = SCRIPT_NAME, SCRIPT = SCRIPT, OUTPUT_NAME = OUTPUT_NAME }
