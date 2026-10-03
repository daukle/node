// Run as a module it reports what the tree it sits in LOADS, and as a script
// with --print it does the same for a process started somewhere else. Both
// halves anchor on import.meta.url, so moving a copy of this file moves what it
// measures, which is the whole mechanism of the native comparison.
//
// It loads rather than resolving, and that is not a style choice: on node
// v22.15.0 a real require() goes through a registerHooks resolve hook and
// require.resolve() does NOT, so a probe built on require.resolve reports every
// package missing on the one release this toolchain names as its floor.
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

export const SPECIFIERS = [
  "dual",
  "plain-cjs",
  "esm-only",
  "@scope/scoped",
  "subpaths",
  "subpaths/deep",
  "dependant",
  "hoisted",
  "no-such-package",
];

const requireFromHere = createRequire(import.meta.url);

function insideModules(location) {
  const path = location.startsWith("file:") ? fileURLToPath(location) : location;
  const forward = path.replace(/\\/g, "/");
  const at = forward.indexOf("/node_modules/");
  return at === -1 ? forward : forward.slice(at + "/node_modules/".length);
}

// A CommonJS package reached through import() arrives as a namespace whose
// default is module.exports, and whether the marker is also a named export
// depends on what the lexer made of the source.
function markerOf(loaded) {
  const where = loaded.where !== undefined ? loaded.where
                : (loaded.default !== undefined ? loaded.default.where : undefined);
  return typeof where === "string" ? insideModules(where) : "NO MARKER";
}

async function attempt(load) {
  try {
    return markerOf(await load());
  } catch (failure) {
    return "ERROR " + (failure.code || failure.name);
  }
}

export async function report() {
  const rows = {};
  for (const specifier of SPECIFIERS) {
    rows[specifier] = {
      cjs: await attempt(async () => requireFromHere(specifier)),
      esm: await attempt(() => import(specifier)),
    };
  }
  return rows;
}

if (process.argv[2] === "--print") process.stdout.write(JSON.stringify(await report()));
