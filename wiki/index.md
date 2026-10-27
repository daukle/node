# daukle/node

The Node toolchain, in managed mode. It provisions a runtime, generates a `package.json` into the
derived directory, and drives the npm that runtime bundles. `node:install` places two entries at
the package root so that a tool which resolves `node_modules` or reads `package.json` itself finds
them, and nothing else is written there.

## Declaring it

```toml
[plugins]
node = "daukle/node@^1"

[toolchains.node]
version = "22"
entry = "src/index.mjs"
```

`daukle node:run` runs the `entry`, and `daukle node:install` installs the dependencies.
`daukle node:tree` writes the installed dependency tree, one `<path> <name>@<version>` line per
package, sorted, to `build/daukle/node/dependency-tree.txt` and to the terminal.

| key | meaning |
| --- | --- |
| `version` | which node daukle runs: an exact version or `>=`, never below `22.15.0`. Required |
| `entry` | the module `node:run` runs. Optional; `node:run` needs it when no script is declared |
| `scripts` | a script per task, below |
| `packages`, `devPackages` | package name to version range |
| `type` | `"module"` or `"commonjs"`: the module system of your own `.js` files, as `type` in a `package.json`. Unset forces nothing. A nested `package.json` below the package root decides for the files under it, as in node, where one with no `type` means CommonJS. `daukle migrate` still blocks such a file, because its resolution fields are not carried, searching every directory but `node_modules`, `.git` and `build/daukle` |

A module of yours, run by `node:run` or a script, has the package root as its working directory: the
directory of the instance (`dir`), or the project root. A relative path in a module means what it
meant under npm. Only `node:install` and `node:tree` work in the generated directory, and `node:tree`
installs on its own rather than depending on `node:install`.

## What `node:install` places at the package root

Some tools do not go through node's module hooks: `tsc`, `vite`, `jest`, `webpack`, `eslint` and
`prettier` resolve `node_modules` or read `package.json` on their own. They need both at the package
root, so `node:install` places them there, even when nothing is declared:

| entry | what it is |
| --- | --- |
| `node_modules` | a link into `build/daukle/<instance>/node_modules`: a junction on Windows, a directory symlink elsewhere |
| `package.json` | a COPY of the generated file, never a link. Its first key is `"//"`, a sentence saying daukle generates it, and it carries the toolchain's `type` |

Where a link is refused (`EPERM`, `ENOTSUP`, `EOPNOTSUPP` or `EINVAL`), or `DAUKLE_NODE_LINK=copy` is set,
`node_modules` becomes a copy marked by a `.daukle-copy` file, and the next `node:install` replaces
it. The bytes placed as `package.json` are kept in `build/daukle/<instance>/__daukle_placed__.json`,
which is how an old copy is told from an edited one.

**Add both to the project's `.gitignore`**: `node_modules` and `/package.json`. Write `node_modules`
with no trailing slash: git classifies a symlink as a file, so `node_modules/`, which matches only
directories, does not ignore the link on Linux or macOS. They are generated,
and `daukle migrate` blocks a project whose `.gitignore` files, read from the project root down to
the package root, do not ignore both, naming the line to add. `.git/info/exclude` and a global
excludes file are not read.

**`node:install` refuses, and changes nothing, when:**

- a real `node_modules` or `package.json` sits at the package root that daukle did not place. Remove
  it: the packages are installed into `build/daukle/<instance>/node_modules`. A project with either,
  which `daukle/node` 2.0.x ignored, is refused from 2.1.0.
- the root `node_modules` is a link pointing elsewhere, even one whose target is missing. When it
  points into another instance's `build/daukle/` the message says two node toolchains cannot share
  one package root.
- the root `package.json` was edited. `node:install` replaces it on every run, so move the change
  into `daukle.toml`.

Messages name project-relative paths. A second `node` instance in one package root is refused too,
for the same reason.

## A script per task, instead of one entry point

A `package.json` carries a `scripts` map, so this toolchain takes one too. **Every script becomes
its own task**, which is what makes a project's second entry point reachable:

```toml
  [toolchains.node.scripts]
  build = { module = "scripts/build.mjs" }
  test = { bin = "vitest", args = ["run"] }
  "lint:fix" = { bin = "eslint", args = [".", "--fix"] }
  release = [{ script = "build" }, { bin = "semver", args = ["-i", "minor"] }]
```

`daukle tasks` then names `node:build`, `node:test`, `node:lint.fix` and `node:release`. A script is
one step or a list of them, run in order and stopping at the first failure, and a step is exactly
one of:

| step | what it runs |
| --- | --- |
| `{ module = "<path>" }` | a module of yours, with the provisioned node |
| `{ bin = "<package>", args = [...] }` | the command an installed package publishes |
| `{ script = "<name>" }` | another script declared here |

**A `:` in a script name becomes a `.` in the task name**, because a task name holds one colon and
that one names the toolchain. The npm script keeps its own spelling; only the task is mapped. Two
scripts that would map to the same task name are refused, naming both. `install`, `run` and `tree`
are not script names, because `node:install`, `node:run` and `node:tree` hold them.

**`entry` is only required when you declare no scripts.** With scripts and no `entry`, `node:run`
tells you which script tasks exist instead.

## Migrating from npm

`daukle migrate` turns a project with a `package.json` into this toolchain, all or nothing: if a
single thing cannot be carried over exactly, nothing is written and the report names it and its row
in `NPM-SURFACE.md` (in `daukle/docs`), which is the list of what npm and Node can do that this
toolchain cannot.

**What migrates**

- `dependencies` and `devDependencies`, as `packages` and `devPackages`.
- `engines.node`, as `version`: the newest pinned node that satisfies the range. With none, the
  newest pinned node.
- `type`, as `type`.
- `main`, as `entry`, when the project declares no scripts.
- `scripts` made of `node <file> <args>`, `npm run <name>` (and `npm test`, `start`, `stop`,
  `restart`) of a declared script, and `<command> <args>` where exactly one direct dependency
  provides the command, joined by `&&`.
- Metadata that no build reads: `name`, `version`, `description`, `license`, `author`,
  `contributors`, `keywords`, `repository`, `homepage`, `bugs`, `private`, `funding`.
- A `package-lock.json` and `node_modules`, which move aside.

**What blocks**

- A shell: a pipe, `||`, `VAR=value`, a glob, a redirect, a line break, a quote that is not a whole
  word, and builtins and keywords such as `cd`, `rm`, `echo`, `exec`, `time`, `exit`, `if`, `for`.
- `npx`, `pnpm`, `yarn`, `bun`, `deno`, `node` followed by a flag, and any other `npm` verb.
- A command no direct dependency provides, or two do.
- A dependency on a local path: `file:`, `link:`, or a path such as `./lib`, `../lib`, `/abs` or a
  `.tgz` file, and a `workspace:` or `catalog:` range.
- Dependencies npm cannot install as declared, with no lockfile and no project `.npmrc`: a version
  that does not exist, or a peer conflict. The blocker carries npm's own error. An install that
  fails for the host's reasons, such as an unreachable registry, is an error, not a blocker.
- A project whose `.gitignore` files do not ignore `node_modules` and `/package.json`, which
  `node:install` places at the package root. The report names the line to add.
- A `package.json` below the package root, in any directory but `node_modules`, `.git` and the
  derived `build/daukle`, and a directory that search cannot list.
- Lifecycle scripts, and a `pre<x>` or `post<x>` beside an `<x>`.
- `workspaces`, `overrides`, `peerDependencies`, `optionalDependencies`, the project's own `bin`,
  `exports`, `imports`, `files`, `publishConfig`, `packageManager` and the other fields
  `NPM-SURFACE.md` records absent, and any field the migrator does not know.
- Every `engines` key other than `node`.
- An `npm-shrinkwrap.json`, `.npmrc`, `.nvmrc` or `.node-version`, and another package manager's
  lockfile: `yarn.lock`, `pnpm-lock.yaml`, `bun.lock` or `bun.lockb`.

**The proof compares dependency trees.** The old project is installed as npm would (with `npm ci`
when it has a lockfile) and its tree written; the new project's `node:tree` must match it byte for
byte. Because a committed lockfile is refused, a project whose lockfile pins older versions than its
ranges now resolve to fails the proof: the report says the build differs and gives both digests, and
both trees are printed so you can compare them. Run `npm update` first to migrate what you would get
today.

**After migrating, untrack the old `package.json`.** It was almost certainly committed, and git
applies ignore rules only to untracked files, so the first `node:install` rewrites a tracked file and
`git commit -a` would commit the generated copy. Run `git rm --cached package.json` (and
`git rm -r --cached node_modules` if `node_modules` was tracked), then commit.

## `node` and `npm` are two halves of one language

They are easy to confuse and they are not alternatives:

| | |
| --- | --- |
| **`daukle/node`** | managed mode. daukle owns the generated `package.json` and provisions the runtime |
| **`daukle/npm`** | adopted mode. It edits a `package.json` **you** own, and needs npm already installed |

They are two repositories because core refuses one chunk to hold both a toolchain and a language.

## How module resolution works

A resolve hook in the derived directory, delivered through `NODE_OPTIONS`. It serves everything that
goes through node's own module hooks, so a dependency resolves without any root entry; the entries
above are for the tools that bypass them.

**Three of its four guards are silent when wrong**: a regression produces a working build that
loaded the wrong module. Every one is proved by mutation in this plugin's own suite, so any edit to
the resolver must be re-mutated rather than merely re-run.

The obvious hook passes every straightforward case and silently hands an ESM importer the `require`
branch of a dual package, which only a comparison against native resolution catches.

## What to know before using it

`NODE_OPTIONS` is set for **every descendant process**. A gate makes the hook decline outside the
project, proved both directly and through a spawned grandchild, but it does not stop the flag being
inherited: a child node pays the cost of loading the resolver, and a tool that parses
`NODE_OPTIONS` itself still sees it.

This plugin reaches the **public npm registry** on every CI run, which a fixture registry would
replace with a test of the fixture.

## What it does not do

A lockfile. The cost is named rather than hidden: without one, what a range resolves to can move
between two runs on different days.

**A shell.** A step names a program and its arguments, never a command line, so `&&`, a pipe, a
glob and an inline `FOO=1` are all outside. Measured across this organization's own tree, that is
7% of real npm scripts; for those, a manifest task's `run = { tool, args }` is the escape hatch.

**`npx`.** It fetches an unpinned package at run time, which is the one thing daukle exists to stop.

**Per-script tasks for a project whose only manifest is `daukle.lua`.** Such a project keeps
`node:install` and `node:run`. A plugin registers its tasks before any overlay is applied and
cannot read an executable manifest, so the scripts are invisible at the moment the tasks are made.
