# Authoring notes

**This repository is scaffolded and unimplemented.** It was created on 2026-10-03 so the spec had
somewhere to land; `plugin.lua`, `lib/runtimes.lua`, `test/` and the example are the work. The
design is `daukle/docs` `superpowers/specs/2026-10-03-npm-toolchain-design.md`, and everything in
it is decided.

## Read before writing a line of the resolver

Section 3 of that spec, and the resolution measurement's **section 7**, which records four defects
in the hook that document originally published. **Three of the four are silent when wrong**: they
return a working module and the wrong one. The published hook also cannot run a single CommonJS
`require`, because `registerHooks` is synchronous and in-thread so `require.resolve` re-enters the
hook.

Every test compares against **what Node does natively with the same tree**, never against an
expected string. A dual package answers either way; only the comparison separates the branches.

## Things already measured, so do not re-derive them

- the floor is Node **v22.15.0** (v23.5.0 in the 23 line), across ten releases;
- `context.conditions` is a `Set` on v22.15.0, v23.5.0 and v24.0.0 and an `Array` on v22.23.3,
  v24.21.0, v25.9.0 and v26.3.1, so ask for `.has` before `.includes`;
- `npm --prefix` reads `package.json` from the prefix under npm 11 and from the CURRENT DIRECTORY
  under npm 10.9.2, which Node v22.15.0 bundles. **Run npm with its working directory in the
  derived tree and do not use `--prefix`**;
- the Windows archive has no `lib/` level, so the path to `npm-cli.js` differs per platform;
- the POSIX tarball's three symlinks are `bin/npm`, `bin/npx` and `bin/corepack`, and this
  toolchain names `npm-cli.js` directly, so none of them is load bearing for it.

## Conventions this repository is held to

`* -text` is pinned, because the cases compare bytes and `core.autocrlf` would rewrite a checkout
on Windows for a reason that has nothing to do with the plugin. `line_endings: true` is set on the
CI caller for the same reason: that pin is also what removes git's own normalisation.

`test/run.sh` runs every case against a **real daukle**, because this plugin's output is npm's and
a stub of `daukle.exec` would be testing the stub.

## The release artifact

Multi-file, so the artifact is a tar named `plugin.lua` holding `plugin.lua` and `lib/*.lua`, the
shape `daukle/c@1.0.0` and `daukle/cmake@1.0.1` already ship. Two traps: the tag is `1.0.0` and
**not** `v1.0.0`, and GNU tar reads a Windows drive letter as a remote host, so a path must be
written `/c/...`.
