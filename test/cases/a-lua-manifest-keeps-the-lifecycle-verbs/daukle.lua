-- No daukle.toml beside this file, which core accepts: with no primary manifest
-- it falls back to the overlay, so daukle.manifest names a Lua file and
-- daukle.parse refuses to run one. Parsing it unguarded is fatal on EVERY
-- command, not merely on the per-script tasks that wanted it, which is what
-- daukle/cmake@1.4.0 shipped.
daukle.config.schema = 1
daukle.config.project = "daukle/node-test"
daukle.config.version = "1.0.0"
daukle.config.modules = {}
daukle.config.plugins = { node = "./plugins/node" }
daukle.config.toolchains = {
  node = {
    version = ">=22.15.0",
    entry = "src/main.mjs",
    scripts = { build = { module = "src/main.mjs" } },
  },
}
