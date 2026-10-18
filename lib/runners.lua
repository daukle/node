local RESOLVER_NAME = "__daukle_resolver__.mjs"
local BIN_RUNNER_NAME = "__daukle_bin__.mjs"

--[[ @implNote three of these four guards return a working module when they are
     wrong, which is why the suite compares every specifier against what node
     resolves natively from a twin tree rather than asserting that a module
     loaded. The anchor is never created: createRequire and pathToFileURL both
     accept a path to a file that does not exist, and it is only there to name
     the directory resolution starts from. ]]
local RESOLVER = [==[
import { createRequire, registerHooks } from "node:module";
import { pathToFileURL, fileURLToPath } from "node:url";
import { dirname, join, resolve as resolvePath } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const anchor = join(here, "__daukle_anchor__.js");
const asIfImportedFrom = pathToFileURL(anchor).href;
const requireFromDerived = createRequire(anchor);
const installedUnder = pathToFileURL(join(here, "node_modules")).href + "/";
const projectUnder = pathToFileURL(resolvePath(here, "..", "..", "..")).href + "/";
const projectFormat = __DAUKLE_TYPE__;

function isProjectJavaScript(url) {
  return projectFormat !== null && url.startsWith(projectUnder) && !url.startsWith(installedUnder)
    && !url.includes("/node_modules/") && url.endsWith(".js");
}

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
  load(url, context, nextLoad) {
    if (isProjectJavaScript(url)) return nextLoad(url, { ...context, format: projectFormat });
    return nextLoad(url, context);
  },
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
]==]

local function resolver_for(project_type)
  local literal = project_type == nil and "null" or ('"' .. project_type .. '"')
  return (string.gsub(RESOLVER, "__DAUKLE_TYPE__", literal))
end

--[[ @implNote an npm bin shim is nothing but "<node> <package>/<bin field>",
     written three times on Windows (sh, .cmd, .ps1) and once as a symlink
     elsewhere, and EVERY shape falls back to a node on PATH when none sits
     beside it, which in a daukle project is the host's node or none at all.
     So the shims are not used: the bin field is read here, by the node this
     toolchain provisioned, with the resolver already loaded through --import.
     That needs no per-platform branch and no cmd.exe.

     Read with fs rather than through a specifier, because a package whose
     "exports" map does not list "./package.json" refuses to resolve it, and
     a direct dependency is at node_modules/<name> by npm's own layout. ]]
local BIN_RUNNER = [==[
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const [packageName, binName, ...rest] = process.argv.slice(2);
const packageRoot = join(here, "node_modules", packageName);

let manifest;
try {
  manifest = JSON.parse(readFileSync(join(packageRoot, "package.json"), "utf8"));
} catch (cause) {
  throw new Error(`"${packageName}" is not installed, so it has no command to run`, { cause });
}

const bin = manifest.bin;
const wanted = binName || packageName;
let target;
if (typeof bin === "string") {
  if (binName && binName !== packageName) {
    throw new Error(`"${packageName}" publishes one command and it is not "${binName}"`);
  }
  target = bin;
} else if (bin && typeof bin === "object") {
  target = bin[wanted];
  if (typeof target !== "string") {
    const offered = Object.keys(bin).sort().join(", ");
    throw new Error(
      `"${packageName}" publishes no command called "${wanted}": set "binName" to one of ${offered}`,
    );
  }
} else {
  throw new Error(`"${packageName}" publishes no command, so there is nothing to run`);
}

// The bin reads its own name and arguments out of argv, exactly as it would
// behind npm's shim, so argv is rewritten before it is imported rather than
// after it has already read the wrong one.
const resolved = resolve(packageRoot, target);
process.argv = [process.argv[0], resolved, ...rest];
await import(pathToFileURL(resolved).href);
]==]

return {
  RESOLVER_NAME = RESOLVER_NAME,
  BIN_RUNNER_NAME = BIN_RUNNER_NAME,
  RESOLVER = RESOLVER,
  resolver_for = resolver_for,
  BIN_RUNNER = BIN_RUNNER,
}
