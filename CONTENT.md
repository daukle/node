## What this plugin is

A `daukle.toolchain` named `node`: it provisions a Node runtime for the host, drives the npm that
runtime bundles, and generates a `package.json` and a module resolver into `build/daukle/node/`.
**No file is placed at the project root**, which is the constraint the whole design was found
under.

It also exports `lib/runtimes`, the table of which Node archive a host needs and where `node` and
`npm-cli.js` sit inside it. A second JavaScript toolchain reaches that through
`daukle.require("node:lib/runtimes")` rather than copying it, which is the layering `daukle/c` and
`daukle/cmake` established.

## Why this is not `daukle/npm`

`daukle/npm` is a `daukle.language` plugin: it edits a `package.json` you own and maintain, which
is adopted mode. This repository is managed mode, and the two cannot share a plugin. Core refuses
it: `lua_declare_language` raises `daukle.provision is available only to a toolchain or publisher
plugin` for any chunk that declared `provision` or `exec`. The managed-mode architecture's
section 4 says one repository may provide both; it is wrong, and `daukle/c` paid for the same
collision first.

## How resolution works without a root file

Node resolves a bare specifier by walking up from the importing file, so dependencies installed
into `build/daukle/node/node_modules` are not reachable from a source file at the project root.
Neither `NODE_PATH` (CommonJS only) nor a root junction (`daukle` must not require symlinks) is
available.

What works is a `module.registerHooks` resolve hook, generated into the derived directory beside the
`node_modules` it points at. It resolves both module systems, needs no root file and no symlink, and
is measured against what Node does natively rather than against an expectation.

**It reaches the process two ways, and both are needed.** `node:run` names it on the command line,
which is correct because a task's working directory is the derived directory. The hook then writes
its own absolute `file://` URL into `NODE_OPTIONS`, which is how a descendant process gets it. A
relative path cannot do that job: `NODE_OPTIONS` is inherited and resolved against each process's
own working directory, so it would kill an unrelated node started elsewhere rather than merely
shadow it.

**It is not a free mechanism and the design says so.** Three of its four guards are silent when
wrong: resolving with `require.resolve` hands an ESM importer the `require` branch of a dual
package, a nested `node_modules` loses to the hoisted copy, and an ungated hook shadows an
unrelated project's own packages through an inherited `NODE_OPTIONS`. Every one of them is mutated
and watched go red in this repository's own suite.

## The minimum Node

**v22.15.0**, and **v23.5.0** within the 23 line, measured across ten releases rather than read off
when the API was added. The toolchain refuses a constraint that could resolve below it, even one
that would in fact resolve above it. The npm version is not independently choosable: it is whatever
the provisioned Node bundles, and the suite runs the whole resolver probe on the floor release for
that reason.

## What it gives up

Reproducibility across machines. npm writes `package-lock.json` into the derived directory and
`daukle clean` removes the whole of it, after which `npm ci` refuses outright. The toolchain is
reproducible between installs on one machine and not between machines or across a clean, and the
design states that rather than implying otherwise.
