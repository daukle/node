# daukle/node

The Node toolchain, in managed mode. It provisions a runtime, generates a `package.json` into the
derived directory, and drives the npm that runtime bundles. **No file of any kind is written at the
project root.**

## Declaring it

```toml
[plugins]
node = "daukle/node@^1"

[toolchains.node]
version = "22"
entry = "src/index.mjs"
```

`daukle node:run` runs the `entry`, and `daukle node:install` installs the dependencies.

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
scripts that would map to the same task name are refused, naming both.

**`entry` is only required when you declare no scripts.** With scripts and no `entry`, `node:run`
tells you which script tasks exist instead.

## `node` and `npm` are two halves of one language

They are easy to confuse and they are not alternatives:

| | |
| --- | --- |
| **`daukle/node`** | managed mode. daukle owns the generated `package.json` and provisions the runtime |
| **`daukle/npm`** | adopted mode. It edits a `package.json` **you** own, and needs npm already installed |

They are two repositories because core refuses one chunk to hold both a toolchain and a language.

## How module resolution works without a root file

A resolve hook in the derived directory, delivered through `NODE_OPTIONS`.

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
