local SCRIPT_NAME = "__daukle_tree__.mjs"
local OUTPUT_NAME = "dependency-tree.txt"

--[[ @implNote dot entries are skipped because npm keeps its own bookkeeping
     there (.bin, .package-lock.json), which differs between an npm ci and an
     npm install of the same tree. ]]
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
  } catch {
    lines.push(`${path} unreadable`);
    return;
  }
  lines.push(`${path} ${manifest.name}@${manifest.version}`);
  walk(join(directory, "node_modules"), path + "/node_modules/");
}

function walk(modules, prefix) {
  if (!existsSync(modules)) return;
  for (const entry of readdirSync(modules, { withFileTypes: true })) {
    if (entry.name.startsWith(".")) continue;
    if (entry.name.startsWith("@")) {
      for (const scoped of readdirSync(join(modules, entry.name))) {
        visit(join(modules, entry.name, scoped), prefix + entry.name + "/" + scoped);
      }
      continue;
    }
    visit(join(modules, entry.name), prefix + entry.name);
  }
}

walk(join(here, "node_modules"), "");
lines.sort();
const text = lines.join("\n") + "\n";
writeFileSync(join(here, "dependency-tree.txt"), text);
process.stdout.write(text);
]==]

return { SCRIPT_NAME = SCRIPT_NAME, SCRIPT = SCRIPT, OUTPUT_NAME = OUTPUT_NAME }
