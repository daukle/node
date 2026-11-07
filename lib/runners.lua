local RESOLVER_NAME = "__daukle_resolver__.mjs"
local BIN_RUNNER_NAME = "__daukle_bin__.mjs"
local REMOVER_NAME = "__daukle_remove__.mjs"
local ECHO_NAME = "__daukle_echo__.mjs"

--[[ @implNote three of these four guards return a working module when they are
     wrong, which is why the suite compares every specifier against what node
     resolves natively from a twin tree rather than asserting that a module
     loaded. The anchor is never created: createRequire and pathToFileURL both
     accept a path to a file that does not exist, and it is only there to name
     the directory resolution starts from.

     There is no load hook, so the project's type travels on the resolve
     result and through Module._extensions instead: on v22.15.0 any synchronous
     load hook routes every CommonJS module through the ESM translator, whose
     require has no cache and no resolve.paths, and that release refuses the
     null source a hook would need to hand the module back. ]]
local RESOLVER = [==[
import Module, { createRequire, isBuiltin, registerHooks } from "node:module";
import { existsSync, readFileSync, realpathSync } from "node:fs";
import { pathToFileURL, fileURLToPath } from "node:url";
import { dirname, join, resolve as resolvePath, sep } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const anchor = join(here, "__daukle_anchor__.js");
const asIfImportedFrom = pathToFileURL(anchor).href;
const requireFromDerived = createRequire(anchor);
const installedUnder = pathToFileURL(join(here, "node_modules")).href + "/";
const projectRoot = resolvePath(here, "..", "..", "..");
const projectUnder = pathToFileURL(projectRoot).href + "/";
const projectFormat = __DAUKLE_TYPE__;

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

// Node resolves a package's own name through the "exports" of the nearest
// package.json, which at the root is the placed copy carrying them, so that
// name is left to node: from the derived directory it would not resolve.
const ownName = __DAUKLE_SELF__;
function namesThisPackage(specifier) {
  return ownName !== null && (specifier === ownName || specifier.startsWith(ownName + "/"));
}

const inWorkspace = __DAUKLE_WORKSPACE__;
const ownModules = realModules(here);
const modulesByDirectory = new Map();

function realModules(directory) {
  try {
    return realpathSync(join(directory, "node_modules"));
  } catch {
    return null;
  }
}

function isInsideProject(directory) {
  return directory === projectRoot || directory.startsWith(projectRoot + sep);
}

/**
 * Whether the nearest node_modules above the importing file is another workspace project's.
 *
 * @implNote each project of a pnpm workspace has modules of its own, so a sibling's file, or a
 * package in the workspace's virtual store, resolves from where it lies, as node would.
 */
function belongsToAnotherWorkspaceProject(parentURL) {
  if (!inWorkspace) return false;
  for (let directory = dirname(fileURLToPath(parentURL)); isInsideProject(directory);
       directory = dirname(directory)) {
    let modules = modulesByDirectory.get(directory);
    if (modules === undefined) {
      modules = realModules(directory);
      modulesByDirectory.set(directory, modules);
    }
    if (modules !== null) return modules !== ownModules;
    if (directory === projectRoot) return false;
  }
  return false;
}

function belongsToThisProject(parentURL) {
  if (typeof parentURL !== "string") return false;
  if (!parentURL.startsWith(projectUnder)) return false;
  return !parentURL.startsWith(installedUnder) && !belongsToAnotherWorkspaceProject(parentURL);
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
  if (resolving || !namesAPackage(specifier) || namesThisPackage(specifier)
      || !belongsToThisProject(context.parentURL)) {
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
]==]

--- The resolver for a project of this type, which leaves `own_name` to node when it is given.
---
--- @param own_name the packed package's name as its JSON text, or nil when it has no `exports`
--- @param in_workspace whether the project is a pnpm workspace's root or member
local function resolver_for(project_type, own_name, in_workspace)
  local type_literal = project_type == nil and "null" or ('"' .. project_type .. '"')
  local with_type = string.gsub(RESOLVER, "__DAUKLE_TYPE__", type_literal)
  local with_workspace = string.gsub(with_type, "__DAUKLE_WORKSPACE__", in_workspace and "true" or "false")
  return (string.gsub(with_workspace, "__DAUKLE_SELF__", function() return own_name or "null" end))
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

--[[ A `remove` step, which is what `rm` was in the script: no shell runs it, so
     the provisioned node does. `rm` without -r refuses a directory and without
     -f refuses a missing path, and rmSync does both the same way. ]]
local REMOVER = [==[
import { rmSync } from "node:fs";

const [recursive, force, ...paths] = process.argv.slice(2);
for (const path of paths) rmSync(path, { recursive: recursive === "1", force: force === "1" });
]==]

--- An `echo` step, printed by the provisioned node as sh's echo prints: words joined by a space.
local ECHO = [==[
process.stdout.write(process.argv.slice(2).join(" ") + "\n");
]==]

return {
  ECHO_NAME = ECHO_NAME,
  ECHO = ECHO,
  REMOVER_NAME = REMOVER_NAME,
  REMOVER = REMOVER,
  RESOLVER_NAME = RESOLVER_NAME,
  BIN_RUNNER_NAME = BIN_RUNNER_NAME,
  RESOLVER = RESOLVER,
  resolver_for = resolver_for,
  BIN_RUNNER = BIN_RUNNER,
}
