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
main = "src/index.mjs"
```

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
