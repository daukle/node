do
  local toolchains = daukle.config.toolchains
  local own = toolchains and toolchains["pnpm"]
  if own ~= nil then
    own.pinnedFrom = {
      packages = { ["debug"] = "4.3.4" },
      devPackages = {  },
      pnpm = "10.34.9",
    }
  end
  local target = toolchains and toolchains["node"]
  if target ~= nil then
    target.pnpmLock = {
      text = [[
lockfileVersion: '9.0'

settings:
  autoInstallPeers: true
  excludeLinksFromLockfile: false

importers:

  .:
    dependencies:
      debug:
        specifier: 4.3.4
        version: 4.3.4

  packages/a:
    dependencies:
      ms:
        specifier: 2.1.3
        version: 2.1.3

  packages/b:
    dependencies:
      a:
        specifier: workspace:*
        version: link:../a
      semver:
        specifier: 7.6.2
        version: 7.6.2

packages:

  debug@4.3.4:
    resolution: {integrity: sha512-PRWFHuSU3eDtQJPvnNY7Jcket1j0t5OuOsFzPPzsekD52Zl8qUfFIPEiswXqIvHWGVHOgX+7G/vCNNhehwxfkQ==}
    engines: {node: '>=6.0'}
    peerDependencies:
      supports-color: '*'
    peerDependenciesMeta:
      supports-color:
        optional: true

  ms@2.1.2:
    resolution: {integrity: sha512-sGkPx+VjMtmA6MX27oA4FBFELFCZZ4S4XqeGOXCv68tT+jb3vk/RyaKWP0PTKyWtmLSM0b+adUTEvbs1PEaH2w==}

  ms@2.1.3:
    resolution: {integrity: sha512-6FlzubTLZG3J2a/NVCAleEhjzq5oxgHyaCU9yYXvcLsvoVaHJq/s5xXI6/XXP6tz7R9xAOtHnSO/tXtF3WRTlA==}

  semver@7.6.2:
    resolution: {integrity: sha512-FNAIBWCx9qcRhoHcgcJ0gvU7SN1lYU2ZXuSfl04bSC5OpvDHFyJCjdNHomPXxjQlCBU67YW64PzY7/VIEH7F2w==}
    engines: {node: '>=10'}
    hasBin: true

snapshots:

  debug@4.3.4:
    dependencies:
      ms: 2.1.2

  ms@2.1.2: {}

  ms@2.1.3: {}

  semver@7.6.2: {}
]],
      pnpm = { version = "10.34.9", url = "https://registry.npmjs.org/pnpm/-/pnpm-10.34.9.tgz", sha256 = "7e8a946108e7baab119e51d27c24d6178b46545422643dbc91e34e2f1ee32e0f" },
      dependencies = { ["debug"] = "4.3.4" },
      devDependencies = {  },
      entries = {
        { path = "debug@4.3.4", url = "https://registry.npmjs.org/debug/-/debug-4.3.4.tgz", sha256 = "04922c9b2e37a6858df2b870a278d1d3a8aaad7ec4c3bd84427f0d53cbf28bcf", as = "debug 4.3.4" },
        { path = "ms@2.1.2", url = "https://registry.npmjs.org/ms/-/ms-2.1.2.tgz", sha256 = "1157a6e30d3ffe1b9fcaf3a39caf159f8dc981199a3380c78ddd89f73bcefb48", as = "ms 2.1.2" },
        { path = "ms@2.1.3", url = "https://registry.npmjs.org/ms/-/ms-2.1.3.tgz", sha256 = "f6616e15e530ed552f9daa2d3ce71963947c6bc7c98c9b64fd3e673fd02622c6", as = "ms 2.1.3" },
        { path = "semver@7.6.2", url = "https://registry.npmjs.org/semver/-/semver-7.6.2.tgz", sha256 = "def1e6490ac0c7810b0b815fe6542f3213d44c95b068059dcac2f81e2c2237a4", as = "semver 7.6.2" },
      },
    }
  end
end

do
  local member = daukle.config.toolchains and daukle.config.toolchains["node-packages-b"]
  if member ~= nil then member.packages.semver = "7.6.2" end
end
