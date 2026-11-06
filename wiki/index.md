# daukle/node

The Node toolchain, in managed mode. It provisions a runtime, generates a `package.json` into the
derived directory, and drives the npm that runtime bundles. Dependencies are `daukle/npm`'s: it
pins them, and `node:install` installs exactly those. `node:install` places two entries at
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
| `type` | `"module"` or `"commonjs"`: the module system of your own `.js` files, as `type` in a `package.json`. Unset forces nothing. A nested `package.json` below the package root decides for the files under it, as in node, where one with no `type` means CommonJS. `daukle migrate` still blocks such a file, because its resolution fields are not carried, searching every directory but `node_modules`, `.git` and `build/daukle` |
| `packageFields` | fields of a `package.json` this toolchain does not model, such as `browserslist`, `lint-staged` or `sideEffects`, each as its own JSON text: `browserslist = '["> 1%"]'`. Written verbatim into the generated `package.json`, which `node:install` places at the package root, so a tool that reads `package.json` itself finds them; npm ignores a field it does not know. A field this toolchain writes or models, or one it has no equivalent for, is refused, and so is text that is not exactly one JSON value. `daukle migrate` writes it for every field it does not know |
| `nestedPackages` | a `package.json` below the package root that marks a module format boundary or is a subpath shim, by directory: `nestedPackages = { "src/legacy" = { type = "commonjs" } }`, `{ main = "../dist/compat.js", types = "../dist/compat.d.ts" }`, or `{}` for one with neither. It carries `type`, `main`, `module` and `types`, plus metadata such as `name` as `packageFields`, each field's JSON text as in the root's. `node:install` places each as a marked copy, as it places the root one, refuses one it did not place or one that was edited, and removes one `daukle.toml` no longer names. `node:pack` packs it without the marker, so a published shim ships the file it declares |

## Dependencies

They are declared in `[toolchains.npm]`, not here, and pinned by `daukle/npm`:

```toml
[plugins]
npm = "daukle/npm@^2"
node = "daukle/node@^4"

[toolchains.npm]
version = "22.15.0"
packages = { react-dom = "^18.3.1" }
devPackages = { typescript = "~5.6.0" }
```

`daukle npm:resolve --resolve` has npm compute the closure and writes it, every package pinned by
sha256, to the committed `daukle/npm/lock.lua`. `node:install` then fetches each package this host
installs against its sha256, hands it to npm's cache, and runs `npm ci --offline`: no range is
resolved and npm reaches no network. A build with ranges and no pins, or ranges changed since the
resolve, is refused naming the resolve command. `packages` and `devPackages` in `[toolchains.node]`
were this toolchain's keys up to 3.x and are refused by name since 4.0.0.

**A pnpm project is pinned by `daukle/pnpm` instead**, declared in `[toolchains.pnpm]` with a
`pnpm` version beside `version`, and resolved with `daukle pnpm:resolve --resolve` into
`daukle/pnpm/lock.lua`. `node:install` fetches each pinned tarball, serves exactly those on a
loopback registry and runs the pinned pnpm with `--frozen-lockfile` against it, so the
`node_modules` is pnpm's own layout and a package left unpinned fails as a 404. One package root
installs with one package manager: npm's and pnpm's pins together are refused.

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

Each `nestedPackages` directory gets the same treatment: a marked copy holding its fields, its
bytes kept in `__daukle_placed_nested__.json`, and an `info/exclude` line.

**Nothing to add to `.gitignore`.** Inside a git repository, `node:install` writes both entries
to that clone's `.git/info/exclude` (the shared one, for a worktree), as `/<path>/node_modules` and
`/<path>/package.json` from the repository root. That file is never committed, so no project file
changes; outside a git repository nothing is written. A `.gitignore` ranks above it, so `daukle
migrate` blocks only a `.gitignore` negation that could re-include either entry, naming it.

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
| `{ remove = [...], recursive = true, force = true }` | deletes paths as `rm -rf` would; without `recursive` a directory is refused, without `force` a missing path is |
| `{ echo = [...] }` | prints its words joined by one space, as `echo` does |
| `{ attempt = [...], otherwise = [...] }` | runs the `attempt` steps, and the `otherwise` steps only when one of them fails, as `a \|\| b` does |

A `module` or `bin` step also takes `env = { NAME = "value" }`, added to the environment it runs in.
**An argument may be `{ passed = true }`**, which takes the words the script was called with, as
`"$@"` does in `sh -c '...' sh`; a script holding one does not also append those words to its last step.
**An argument may be `{ glob = "<pattern>" }`**, expanded against the package root just before the
step runs, as POSIX `sh` expands an unquoted glob: `*`, `?` and `[...]` within one directory (`**` is
`*`), dotfiles only for a pattern starting with `.`, sorted, and the pattern itself when it matches
nothing. That is the same on every host, including Windows, where `cmd.exe` would not expand it.

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

- A project `.npmrc`, as `npmConfig` in `[toolchains.npm]`, which every npm daukle runs reads as
  `npm_config_*`; the file moves aside.
- `overrides`, as its JSON text in `[toolchains.npm]`, which the resolve and every install read.
  An `overrides` beside no dependency blocks, since it would have nowhere to go.
- `dependencies` and `devDependencies`, as `packages` and `devPackages` in `[toolchains.npm]`,
  pinned from the project's own `package-lock.json` when it is version 2 or later, so the migrated
  project installs exactly what it did, and from a fresh resolve otherwise. Pinning fetches every
  package once, so a project with dependencies migrates as `daukle migrate --resolve`; without
  the flag the report names it.
- `engines`, verbatim as `packageFields.engines`, and as `version`: the newest pinned node that
  satisfies `engines.node` and whose bundled npm satisfies `engines.npm`. With neither, the newest
  pinned node.
- Every other field it does not know, verbatim as `packageFields`.
- A `package.json` below the package root that declares only `type`, `main`, `module`, `types`
  and metadata such as `name`, as `nestedPackages`; the file moves aside and `node:install` places a generated one.
- `type`, as `type`.
- `main`, as `entry`, when the project declares no scripts.
- `scripts` made of `node <file> <args>`, `npm run <name>` (and `npm test`, `start`, `stop`,
  `restart`) of a declared script, and `<command> <args>` where a package at the top of the installed
  `node_modules` provides the command, the one npm's own `.bin` links when two do, joined by `&&`.
- Metadata that no build reads: `name`, `version`, `description`, `license`, `author`,
  `contributors`, `keywords`, `repository`, `homepage`, `bugs`, `private`, `funding`.
- A `package-lock.json` and `node_modules`, which move aside.

**What blocks**

- A shell: a pipe, `||`, `VAR=value`, a glob, a redirect, a line break, a quote that is not a whole
  word, and builtins and keywords such as `cd`, `rm`, `echo`, `exec`, `time`, `exit`, `if`, `for`.
- `npx`, `pnpm`, `yarn`, `bun`, `deno`, `node` followed by a flag, and any other `npm` verb.
- A command no installed package provides.
- A dependency on a local path: `file:`, `link:`, or a path such as `./lib`, `../lib`, `/abs` or a
  `.tgz` file, and a `workspace:` or `catalog:` range.
- Dependencies npm cannot install as declared, with no lockfile, under the project `.npmrc`: a version
  that does not exist, or a peer conflict. The blocker carries npm's own error. An install that
  fails for the host's reasons, such as an unreachable registry, is an error, not a blocker.
- A `.gitignore` negation that could re-include the `node_modules` or `package.json` that
  `node:install` places at the package root. The report names the negation.
- A `package.json` below the package root that declares more than `type` and metadata (its own
  dependencies, scripts, `imports`, `exports` or `main`), in any directory but `node_modules`,
  `.git` and the derived `build/daukle`, and a directory that search cannot list.
- Lifecycle scripts, and a `pre<x>` or `post<x>` beside an `<x>`.
- `workspaces`, `peerDependencies`, `optionalDependencies`, the project's own `bin`,
  `exports`, `imports`, `files`, `publishConfig`, `packageManager` and the other fields
  `NPM-SURFACE.md` records absent, and a field named with an escape it cannot carry verbatim.
- An `engines.node` or `engines.npm` range no pinned release satisfies, or one it cannot read, and
  an `engines` that is not a map.
- An `.npmrc` key `daukle/npm` refuses (a registry, a credential, a `${VAR}` value, a key daukle sets
  itself), an ini section or list, or an `.npmrc` beside a package with no dependencies.
- An `npm-shrinkwrap.json`, `.nvmrc` or `.node-version`, and another package manager's
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
`git rm -r --cached node_modules` if `node_modules` was tracked, and the same for each
`nestedPackages` directory's `package.json`), then commit.

## `node` and `npm`

`daukle/node` is the toolchain: daukle owns the generated `package.json` and provisions the
runtime. `daukle/npm` is being redesigned as its resolver, pinning every package of the closure by
its registry integrity digest; nothing of that is released yet.

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

**A shell.** A step names a program and its arguments, never a command line. `daukle migrate`
translates the common shell syntax into steps instead (`D-227`, `D-249`): `a && b`, `a || b`,
`NAME=value cmd`, an unquoted glob argument, `rm`, `echo` without flags, and `sh -c '<body>' <name>`
whose body is itself in this subset, each `"$@"` in it taking the passed words. Everything else a
shell would do still blocks by name: a pipe, `;`, redirection, `$(...)`, `cd` and the other builtins. For those, a manifest task's
`run = { tool, args }` is the escape hatch.

**`npx`.** It fetches an unpinned package at run time, which is the one thing daukle exists to stop.

**Per-script tasks for a project whose only manifest is `daukle.lua`.** Such a project keeps
`node:install` and `node:run`. A plugin registers its tasks before any overlay is applied and
cannot read an executable manifest, so the scripts are invisible at the moment the tasks are made.
