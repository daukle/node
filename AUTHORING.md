# Authoring notes

The design is `daukle/docs` `superpowers/specs/2026-10-03-npm-toolchain-design.md`. **Four of its
claims were measured false while implementing it** and are corrected below; the corrections are the
most useful part of this file, because each one was arrived at by running something rather than by
reading.

## What the implementation found that the spec did not

**A plugin has no absolute path to the project, so `NODE_OPTIONS` cannot be built in Lua.**
`context.root` is the literal string `"../../.."`, relative to the derived directory a task runs
in. The spec's section 7 has the plugin assemble `--import <resolver>` and hand it to
`daukle.exec`'s `env`, and there is nothing to assemble it from.

**A relative `--import` is worse than no gate at all.** It is resolved against **each process's
own** working directory, so an unrelated node started elsewhere under an inherited `NODE_OPTIONS`
dies with `ERR_MODULE_NOT_FOUND` naming a path in its own tree, rather than merely being shadowed.
An absolute PATH is refused too, on Windows: `Only URLs with a scheme in: file, data, and node are
supported ... Received protocol 'c:'`. **A `file://` URL is the one spelling that is neither**, and
it percent-encodes a space, so `NODE_OPTIONS` never needs quoting.

So the resolver is delivered **twice, by two mechanisms**. `node:run` passes
`--import ./__daukle_resolver__.mjs` on the command line, which is correct because a task's working
directory is the derived directory. The resolver then writes the absolute form into
`process.env.NODE_OPTIONS` itself, from its own `import.meta.url`, which is how a descendant gets
it. That is the spec's semantics with the one step the plugin could not take moved into the file
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
