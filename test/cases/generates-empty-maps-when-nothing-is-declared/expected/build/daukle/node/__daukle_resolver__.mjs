import { createRequire, registerHooks } from "node:module";
import { pathToFileURL, fileURLToPath } from "node:url";
import { dirname, join, resolve as resolvePath } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const anchor = join(here, "__daukle_anchor__.js");
const asIfImportedFrom = pathToFileURL(anchor).href;
const requireFromDerived = createRequire(anchor);
const installedUnder = pathToFileURL(join(here, "node_modules")).href + "/";
const projectUnder = pathToFileURL(resolvePath(here, "..", "..", "..")).href + "/";

function isBare(specifier) {
  if (specifier === "") return false;
  if (specifier[0] === "." || specifier[0] === "/") return false;
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

registerHooks({
  resolve(specifier, context, nextResolve) {
    if (resolving || !isBare(specifier) || !belongsToThisProject(context.parentURL)) {
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
  },
});
