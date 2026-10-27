import Module, { createRequire, isBuiltin, registerHooks } from "node:module";
import { existsSync, readFileSync } from "node:fs";
import { pathToFileURL, fileURLToPath } from "node:url";
import { dirname, join, resolve as resolvePath } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const anchor = join(here, "__daukle_anchor__.js");
const asIfImportedFrom = pathToFileURL(anchor).href;
const requireFromDerived = createRequire(anchor);
const installedUnder = pathToFileURL(join(here, "node_modules")).href + "/";
const projectRoot = resolvePath(here, "..", "..", "..");
const projectUnder = pathToFileURL(projectRoot).href + "/";
const projectFormat = null;

// Node takes a file's type from its NEAREST package.json, and one with no
// "type" means CommonJS, so a package.json below the root decides for the
// files under it; at the root, daukle.toml's type plays that file's part.
const nestedManifestByDirectory = new Map();
function hasNestedManifest(directory) {
  if (directory === projectRoot || !directory.startsWith(projectRoot)) return false;
  let found = nestedManifestByDirectory.get(directory);
  if (found === undefined) {
    found = existsSync(join(directory, "package.json")) || hasNestedManifest(dirname(directory));
    nestedManifestByDirectory.set(directory, found);
  }
  return found;
}

function isProjectJavaScript(url) {
  return projectFormat !== null && url.startsWith(projectUnder) && !url.startsWith(installedUnder)
    && !url.includes("/node_modules/") && url.endsWith(".js")
    && !hasNestedManifest(dirname(fileURLToPath(url)));
}

const loadJavaScriptNatively = Module._extensions[".js"];

function compileInProjectFormat(module, filename) {
  module._compile(readFileSync(filename, "utf8"), filename, projectFormat);
}

if (projectFormat !== null) {
  Module._extensions[".js"] = function (module, filename) {
    if (isProjectJavaScript(pathToFileURL(filename).href)) return compileInProjectFormat(module, filename);
    return loadJavaScriptNatively(module, filename);
  };
}

// A builtin named without "node:" is bare too, and require.resolve answers it
// with its own name, which pathToFileURL would turn into a file in the cwd.
function namesAPackage(specifier) {
  if (specifier === "") return false;
  if (specifier[0] === "." || specifier[0] === "/") return false;
  if (isBuiltin(specifier)) return false;
  return !/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(specifier);
}

function belongsToThisProject(parentURL) {
  if (typeof parentURL !== "string") return false;
  if (!parentURL.startsWith(projectUnder)) return false;
  return !parentURL.startsWith(installedUnder);
}

// Iterated rather than indexed, because the shape is not one thing: node
// v22.15.0 hands an Array to an ESM resolve and a Set to a CommonJS one, and
// v26.3.1 hands an Array to both. A branch per shape would leave whichever one
// the running node does not use untested, and includes() over a Set answers
// false rather than throwing, so the wrong branch would be silent.
function hasCondition(conditions, name) {
  if (conditions == null) return false;
  for (const condition of conditions) if (condition === name) return true;
  return false;
}

// A descendant gets the hook through NODE_OPTIONS, which has to name an
// absolute file URL: node refuses an absolute PATH to --import on Windows and
// resolves a relative one against each process's own working directory, which
// would kill an unrelated node started elsewhere rather than merely shadow it.
// Prepended rather than assigned, so whatever the user exported survives, and
// skipped when it is already there, so it does not grow a flag per generation.
const inheritedOptions = process.env.NODE_OPTIONS;
if (!inheritedOptions) {
  process.env.NODE_OPTIONS = "--import " + import.meta.url;
} else if (!inheritedOptions.includes(import.meta.url)) {
  process.env.NODE_OPTIONS = "--import " + import.meta.url + " " + inheritedOptions;
}

let resolving = false;

function resolveSpecifier(specifier, context, nextResolve) {
  if (resolving || !namesAPackage(specifier) || !belongsToThisProject(context.parentURL)) {
    return nextResolve(specifier, context);
  }
  if (hasCondition(context.conditions, "import")) {
    return nextResolve(specifier, { ...context, parentURL: asIfImportedFrom });
  }
  resolving = true;
  try {
    return { url: pathToFileURL(requireFromDerived.resolve(specifier)).href, shortCircuit: true };
  } finally {
    resolving = false;
  }
}

registerHooks({
  resolve(specifier, context, nextResolve) {
    const resolved = resolveSpecifier(specifier, context, nextResolve);
    if (isProjectJavaScript(resolved.url)) return { ...resolved, format: projectFormat };
    return resolved;
  },
});
