# Authoring notes

The design is `daukle/docs` `superpowers/specs/2026-10-03-npm-toolchain-design.md`. **Four of its
claims were measured false while implementing it** and are corrected below; the corrections are the
most useful part of this file, because each one was arrived at by running something rather than by
reading.

## What the implementation found that the spec did not

**A plugin has no absolute path to the project, so `NODE_OPTIONS` cannot be built in Lua.**
`context.root` is the literal string `"../../.."`, relative to the derived directory (for an
instance with `dir = "web"` it is `"../../../web"`). The spec's section 7 has the plugin
assemble `--import <resolver>` and hand it to `daukle.exec`'s `env`, and there is nothing to
assemble it from.

**A relative `--import` is worse than no gate at all.** It is resolved against **each process's
own** working directory, so an unrelated node started elsewhere under an inherited `NODE_OPTIONS`
dies with `ERR_MODULE_NOT_FOUND` naming a path in its own tree, rather than merely being shadowed.
An absolute PATH is refused too, on Windows: `Only URLs with a scheme in: file, data, and node are
supported ... Received protocol 'c:'`. **A `file://` URL is the one spelling that is neither**, and
it percent-encodes a space, so `NODE_OPTIONS` never needs quoting.

So the resolver is delivered **twice, by two mechanisms**. `node:run` and every script step pass
`--import <derived directory>/__daukle_resolver__.mjs` on the command line, as a path relative to
the package root they run in, starting with `./` or `../` so it stays a relative URL rather than a
bare specifier. The resolver then writes the absolute form into `process.env.NODE_OPTIONS` itself,
from its own `import.meta.url`, which is how a descendant gets it. That is the spec's semantics with the one step the plugin could not take moved into the file
that can take it.

**`context.conditions` is not one shape per version, it is one shape per MODULE SYSTEM.** Measured
on both ends of the supported range:

| node | ESM resolve | CommonJS resolve |
| --- | --- | --- |
| v22.15.0 | `Array` | `SafeSet` |
| v26.3.1 | `Array` | `Array` |

The spec's section 4 reads this as a version difference and adds a `conditions.has` branch "to put
the active 22 LTS inside the supported range". **Removing that branch changes nothing on either
release**, proved by mutation: the hook only ever asks whether `import` is present, which is the ESM
path, which is an `Array` everywhere. `Array.prototype.includes.call` over a `Set` also answers
`false` rather than throwing, which the spec says it does. A per-shape branch would therefore leave
one branch untested on whichever node is running, and be silent when wrong, so there is **one path
that iterates** and both module systems exercise it on every resolve.

**`require.resolve()` does not go through the hook on v22.15.0, and `require()` does.** This is a
property of the instrument rather than of the resolver, and it cost a whole probe: a suite built on
`require.resolve` reports every package missing on the one release this toolchain names as its
floor, while the plugin works there perfectly. **The probe therefore LOADS every specifier and
compares the file that loaded**, which is the better assertion anyway.

**`npm ci` is not reachable and is not wanted.** The spec's section 8 picks `ci` when a lockfile is
present, and **a plugin cannot ask whether a file exists**: `daukle.read` raises on a missing file
and `pcall` is not in the sandbox. It is also the wrong verb here. `ci` refuses when the lockfile
disagrees with `package.json`, daukle GENERATES `package.json`, so the only way they can disagree is
that the manifest changed, which is exactly when reconciling is right and refusing is wrong.

## Read before writing a line of the resolver

Three of its four guards are **silent when wrong**: they return a working module and the wrong one.
Nothing in `test/fixtures/probe/` asserts that a module loaded. Every specifier is compared against
what node loads natively from a twin of the same tree, run as a child with `NODE_OPTIONS` cleared,
and against a control in which the resolver is absent and **every** specifier must fail. The control
is what catches the suite accidentally measuring an ancestor directory's `node_modules`.

Every guard was mutated and watched go red through the real harness. The one that does **not** redden
on the floor release is the re-entrancy flag, because `require.resolve` does not re-enter the hook
there; the newest-release case covers it.

## Things already measured, so do not re-derive them

- the floor is Node **v22.15.0** (v23.5.0 in the 23 line), across ten releases. The 23 line is not
  pinned here, so its sub-floor cannot be reached;
- `npm --prefix` reads `package.json` from the prefix under npm 11 and from the CURRENT DIRECTORY
  under npm 10.9.2, which Node v22.15.0 bundles. **Run npm with its working directory in the
  derived tree and do not use `--prefix`**;
- the Windows archive has no `lib/` level, so the path to `npm-cli.js` differs per platform;
- the POSIX tarball's three symlinks are `bin/npm`, `bin/npx` and `bin/corepack`, and this
  toolchain names `npm-cli.js` directly, so none of them is load bearing for it and `D-57` does not
  bind;
- core refuses a non-string `toolchains.node.version` before the plugin sees it, with
  `toolchains.node.version must be a string`. The plugin's own type check is reachable only through
  `daukle.require("node:lib/runtimes")`, where the caller is another plugin, and it has a case there.

## The scripts map, and why it does not run npm's shims

**A package's `scripts` map is modelled as a map of name to STEP**, each step a one-key table
(`{ module = ... }`, `{ bin = ..., args = [...] }` or `{ script = ... }`). A command STRING is
deliberately not a step, because it is the place a shell would get in: measured over this tree,
**7% of the ~900 npm scripts here need true shell features**, and those stay outside with `D-53`'s
`run = { tool, args }` as the answer. Three step kinds cover **82%**, and each of the remaining
18% has a named reason (`npx` is unpinned, `bun` is a second runtime, the rest is `D-53`).

**A `bin` step does not run `node_modules/.bin/<name>`.** Measured against a real npm install:
npm writes **three shims on Windows** (a `/bin/sh` script, `.cmd` and `.ps1`) and a symlink
elsewhere, and the whole body of each is `<node> <package>/<bin field> "$@"` **falling back to a
node on `PATH`** when none sits beside it. In a daukle project that is the host's node or none, so
the shims are both unportable and wrong. The generated `__daukle_bin__.mjs` reads the package's
own `bin` field instead and imports the target, under the node this toolchain provisioned and with
the resolver already loaded. It reads `package.json` with `fs` rather than through a specifier,
because a package whose `exports` map omits `./package.json` refuses to resolve it.

**An npm script name maps to a task name one way: `:` becomes `.`, then lowercase.** Measured over
this tree: **381 of 904 script names contain a colon**, which a task name cannot hold twice, and
**not one contains a literal dot** against **137 containing a hyphen**. So `.` is the separator
that cannot collide with a name a project already has, and all 904 names here map cleanly. The npm
script keeps its own spelling; only the task is mapped. **A collision is refused, naming both
scripts**, because a duplicate task is fatal in core and would otherwise name neither.

**`entry` is required only when no script is declared.** A project that declares scripts has named
several things to run and has no reason to elect one; `node:run` then refuses and names the script
tasks, which is `daukle/cmake`'s shape for the same problem. A project with neither syncs and
installs, and only `node:run` refuses.

**`install`, `run` and `tree` are not script names**, because `node:install`, `node:run` and
`node:tree` hold them.

**The script tasks are the union over every `node` instance.** A plugin's tasks are declared once
and core repeats them per instance, so an instance `node-web` lists a script only another instance
declares, and running it there fails naming the script rather than doing something else.

**A project whose ONLY manifest is `daukle.lua` gets no per-script task**, keeping `node:install`
and `node:run`. Core accepts such a project by falling back to the overlay when no primary exists,
so `daukle.manifest` names a Lua file, and `daukle.parse` refuses to run an executable format with
no `pcall` available to soften it. Nothing a chunk can reach sees a Lua-declared config, so the
alternative to this boundary is not more tasks but a crash on **every** command: that is what
`daukle/cmake@1.4.0` shipped and `1.4.1` fixed.

## Where a task runs

`node:install` and `node:tree` run in the derived directory `build/daukle/<instance>/`, because npm
reads the `package.json` beside its working directory. `node:tree` installs on its own instead of
depending on `node:install`, because the migration proof runs before core moves the old
`package.json` aside and must not place the root entries. `node:run` and every script step run with
the package root as their working directory, which is the instance's `dir` or the project root, so a
module reading `./data.json` reads the project's file as it would under npm. The package root is
recovered from `context.root` by stripping its leading `../../../`, which is the only way `dir`
reaches the plugin.

## The project's own `type`

The generated `package.json` carries the toolchain's `type`, and so does the copy placed at the
package root. The resolver still enforces it, because a nested `package.json` is a format boundary
for node and the key `type` (`"module"` or `"commonjs"`) overrides it; the resolver is generated with
the value written into it. It applies to a `.js` file under the project and outside any `node_modules`, and
overrides what a nested `package.json` says; `.mjs` and `.cjs` keep their fixed formats. With no
`type` nothing is forced.

**`"module"` goes through the `load` hook**, which hands the format to `nextLoad`; that is honoured
on 22.15.0, 24.21.0 and 26.3.1. **`"commonjs"` needs more.** The hook's format is not honoured for
CommonJS on 24.21.0 and 26.3.1 (measured), so the resolver also wraps `Module._extensions[".js"]`
and compiles the file as CommonJS. That is a deprecated-but-supported node API and no supported
alternative was found; it is why ESM syntax under `"commonjs"` is a SyntaxError on every pin.

## What `node:install` places at the package root

`node:install` ends by running a generated `__daukle_link__.mjs` (`lib/links.lua`) with the
provisioned node. It places `node_modules` and `package.json` at the package root, because tools such
as `tsc` 7, `vite` 8 and `jest` 30 resolve them by walking up from the source file and no other
location is reachable. The design is `daukle/docs`
`superpowers/specs/2026-10-18-tools-that-resolve-node-modules-design.md`, sections 6 and 9, and the
cases that prove it are `tsc-7-finds-node-types-through-the-root`,
`vite-8-bundles-a-dependency-through-the-root` and `jest-30-finds-its-root-and-a-dependency`.

**`package.json` is always a marked COPY, never a link.** Core writes a generated file by atomic
rename (`fr_derived_apply`, `src/project/derived.c`). A symlink would carry a user's edit of the root
file into the generated one, which the next sync overwrites with only a notice. A hard link goes
stale on every sync that changes the file. Only a copy lets `node:install` see an edit and refuse it.
Sync cannot refuse it, because it cannot read the root file conditionally.

**What marks an entry as daukle's.** The generated `package.json` has `"//"` as its first key, a
sentence saying daukle generates it (`"//"` is the key npm documents as ignored). A copied
`node_modules` holds a `.daukle-copy` file. A linked `node_modules` is a symbolic link (node reports a
junction as one) whose target is this instance's `build/daukle/<instance>/node_modules`.

**The edit check has a memory.** The bytes placed are written to
`build/daukle/<instance>/__daukle_placed__.json`. A marked root `package.json` with no such file, as
after `daukle clean`, is replaced. With the file and different bytes it is refused, which is how an
older generation after a manifest change is told from a hand edit.

**`node_modules` is a junction on Windows (it needs no privilege) and a `"dir"` symlink elsewhere,**
and it is always created, even when nothing is declared. It degrades to a marked copy on `EPERM`, `ENOTSUP` or `EINVAL`. The environment
variable `DAUKLE_NODE_LINK=copy` forces that, and is the only way to make a link fail on a CI runner.

**It refuses, never replaces, what it did not place.** A real root `node_modules` or `package.json`,
a `node_modules` link pointing elsewhere (naming that two node toolchains cannot share one package
root, when it points into another instance), and an edited root `package.json`. The migrator
(`ROOT_ENTRIES`, `lib/migrator.lua`) blocks a project whose `.gitignore` files, read from the project
root down to the package root, do not ignore `node_modules/` and `/package.json`.

**`node:tree` does not place them.** Core runs the migration proof (`<instance>:tree`) before it moves
the old `package.json` aside (`fr_migrate_finish`, `src/migrate/migrate_finish.c`), so the proof
cannot depend on `node:install`.

## Migrating from npm

`daukle migrate` turns a `package.json` project into a `node` toolchain through the migrator in
`lib/migrator.lua`, which uses `lib/translate.lua`, `lib/command_line.lua` and `lib/engines.lua`.
The design is `daukle/docs` `superpowers/specs/2026-10-18-npm-migrator-design.md`, and the list of
what npm can do that this toolchain cannot is `daukle/docs` `NPM-SURFACE.md`; every blocker names
one of its rows.

- **`run` reads `package.json` with `daukle.read` and installs its dependencies into
  `migrate-probe/`** with `--ignore-scripts`, to learn which direct dependency provides each command
  a script runs and which of `package-lock.json`, `npm-shrinkwrap.json`, `node_modules`, `.npmrc`,
  `.nvmrc`, `.node-version`, `yarn.lock`, `pnpm-lock.yaml`, `bun.lock` and `bun.lockb` exist.
  Existence is asked of node because `daukle.read` raises on a missing file and the sandbox has no
  `pcall`. The install's output is captured, so `daukle migrate` is silent while it runs. It runs
  with `check = false`, and `lib/npm_errors.lua` reads npm's `npm error code` line: a resolution
  code (`ETARGET`, `E404`, `ERESOLVE`, `EUNSUPPORTEDPROTOCOL`, `EINVALIDTAGNAME`, `E401`, `E403`)
  is one blocker carrying npm's lines and its log path, beside the file blockers, with only the
  bins step skipped. Any other code, or none, is the host's failure and a plugin error (exit 1).
- **Nothing is dropped silently.** An unknown field, every `engines` key other than `node`, a
  non-map `engines`, a dependency name or a `main` that `lib/settings.lua` would refuse, a
  `workspace:` or `catalog:` range, and the files above other than `package-lock.json` and
  `node_modules` are blockers. Metadata that no build reads is dropped by name.
  `package-lock.json` and `node_modules` are owned and move aside.
- **A script becomes steps by a closed grammar.** Whitespace-separated words joined by `&&`; a
  newline, a quote that is not a whole word, any shell character in `lib/command_line.lua` and its
  shell builtins and keywords refuse the script. Single quotes are read with their `sh` meaning on
  every host.
- **`build` is the proof.** It installs the OLD project in `migrate-old/` (`npm ci` when a lockfile
  exists) and writes its tree; the proof task is `node:tree` on the migrated project, and the two
  are compared as bytes. A project with a lockfile fails whenever a range has moved since it was
  written, which is the cost of refusing a committed lockfile. Core prints that the new build
  differs and both digests; it does not list the differing packages, and both trees are on stdout.

## Decisions this implementation took that the spec left open

**A constraint resolves to the NEWEST pinned release that satisfies it.** `">=22.15.0"` takes
26.3.1 today; `"22.15.0"` takes that one exactly. The alternative, taking the lowest, was rejected
because `>=` states what a project tolerates rather than what it wants. The consequence is java's:
what a constraint resolves to moves only with a release of this plugin, never with the host and
never with "whatever is newest on nodejs.org".

**A lower bound below the floor is refused even when it would resolve above it.** `">=20"` would
pick 26.3.1 and work, and the project would still be claiming it runs on a node where the resolver
cannot exist.

**This is the refusal you are most likely to meet, and the reason is a confusion worth naming.**
Measured 2026-10-06: **109 `package.json` files under `F:/Documents/GitHub` declare
`engines.node`, and 100 of them accept node 20.** The natural move when migrating is to copy that
value into this key, and it is refused.

**They are not the same fact.** `version` here is **which node daukle RUNS**; `engines.node` is what
your published package supports. **The generated `package.json` carries no `engines` at all**, so
this toolchain never touches yours: write `">=22.15.0"` here and keep your own range where it was.
The refusal says so now.

**`version` has no default.** `daukle/java` defaults because a JDK major is a thing a project can
have no opinion about; the node release here also fixes the npm major, which it cannot.

## Conventions this repository is held to

`* -text` is pinned, because the cases compare bytes and `core.autocrlf` would rewrite a checkout on
Windows for a reason that has nothing to do with the plugin. `line_endings: true` is set on the CI
caller for the same reason: that pin is also what removes git's own normalisation. **Audit the
blobs after any editing session**, because nothing in CI looks at this:

```sh
git ls-files | while read -r f; do git show "HEAD:$f" \
  | python -c "import sys; b=sys.stdin.buffer.read(); print('$f') if b.count(b'\r\n') else None"; done
```

`test/run.sh` runs every case against a **real daukle**, because this plugin's output is node's and
npm's and a stub of `daukle.exec` would be testing the stub. A case carrying `needs-node` downloads
a runtime and reaches the registry, so it is skipped unless `DAUKLE_NODE_E2E=1` is set; CI sets it
on all three runners, because the per-platform archives and the floor release are exercised by
nothing else.

## The release artifact

Multi-file, so the artifact is a tar named `plugin.lua` holding `plugin.lua` and `lib/*.lua`, the
shape `daukle/c@1.0.0` and `daukle/cmake@1.0.1` already ship. Two traps: the tag is `1.0.0` and
**not** `v1.0.0`, and GNU tar reads a Windows drive letter as a remote host, so a path must be
written `/c/...`.
