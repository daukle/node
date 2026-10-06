# node-hello-dependency

A managed Node project with a dependency. The repository holds `daukle.toml` and `src/` and
**nothing else**: no `package.json`, no `package-lock.json`, no `node_modules`, no `.npmrc`, and no
link of any kind at the project root. daukle downloads a Node runtime, verifies it against a digest
the plugin pins, generates a `package.json` into `build/daukle/node/`, and drives the npm that
runtime bundles.

```console
$ daukle node:run
hello from daukle: 42 is even
```

`daukle node:install` provisions node and installs `is-even` into `build/daukle/node/`, and
`node:run` does that first if needed. `daukle tasks` lists the two tasks and their order.

Run `ls` afterwards. The root still holds only `daukle.toml`, `src/` and `build/`.

## What to look at

**`src/main.mjs` imports `is-even` as a bare specifier**, and `node_modules` is three directories
away in `build/daukle/node/`, which node's own resolution would never find. What finds it is
`__daukle_resolver__.mjs`, generated beside those packages and handed to node with `--import`. It
is a `module.registerHooks` resolve hook, it covers `import` and `require` alike, and it needs no
file at the project root and no symlink.

**This example names a published coordinate, exactly as your project would**, so the directory can
be copied anywhere and `daukle sync` works. The suite runs it twice, once as committed against the
published release and once with this repository's working tree staged over a copy, so a break in
the plugin as it stands reddens this repository rather than waiting for a release. The two lines
are a pinned resolver and a coordinate:

```toml
[resolvers.github]
url = "https://raw.githubusercontent.com/daukle/daukle/<commit>/plugins/github-releases.lua"
sha256 = "..."

[plugins]
node = { resolver = "github", coordinate = "daukle/node@^1.0.0" }
```

Nothing vendors a copy of the plugin either way.

**`version` is a constraint and the plugin pins what satisfies it.** `">=22.15.0"` takes the newest
Node this plugin carries a digest for; `"22.15.0"` takes that one exactly. Anything that could
resolve below 22.15.0 is refused outright, because the resolver this toolchain depends on does not
exist there. The npm version is not separately choosable: it is whatever the Node release bundles.

**`.mjs`, not `.js`.** The generated `package.json` sits in the derived directory, which is not an
ancestor of `src/`, so it cannot tell node that your sources are modules. The extension can, and
`.cjs` works the same way for CommonJS. A project that wants `"type": "module"` to apply to its own
sources writes its own `package.json` at the root, which daukle neither generates nor reads.

## What this example cannot show

**A lockfile you can commit.** npm writes `package-lock.json` beside the generated `package.json`,
inside `build/daukle/node/`, and `daukle clean` deletes the whole derived tree. So the install is
reproducible between runs on this machine and **not** between machines or across a clean. That is a
deferral with the cost named rather than a claim the cost is small; the design records the two
shapes that would buy the property back and why neither was taken.

**Resolution that daukle can see.** npm turns `is-even = "1.0.0"` into a url and a digest, and
daukle never sees either. Every other acquisition in daukle is pinned by sha256 and this one is
not, because it is npm's. A toolchain that delegated resolution has not answered the question of
what daukle resolves; it has avoided needing to.

**`npm run`, workspaces, `npx`, or publishing.** None is modelled. A project needing one of them
reaches for a project-level `run` task, which is the escape hatch the architecture leans on.

## The first run is slow

Roughly 50 MB of Node, with no progress reported while it downloads, and then npm reaching the
registry. It is cached per digest afterwards, shared by every project on the machine that pins the
same release.

## The one file that is a harness input rather than part of the example

`needs-tools` marks this example as one that downloads a runtime and reaches the registry, so a
local run skips it unless `DAUKLE_EXAMPLE_E2E=1` is set. CI sets it on every runner. The `console`
block above is **executed** rather than decorative: its `$ ` line is run and the line beneath it
must appear in the output, so the command and its result cannot drift apart the way a separate
expectation file did.
