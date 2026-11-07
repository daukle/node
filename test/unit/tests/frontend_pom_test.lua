local frontend_pom = daukle.require("lib/frontend_pom")
local expect = daukle.require("tests/expect")

local function plugin(configuration)
  return "<plugin><groupId>com.github.eirslett</groupId><artifactId>frontend-maven-plugin</artifactId>"
         .. "<executions><execution><goals><goal>install-node-and-npm</goal></goals>"
         .. "<configuration>" .. configuration .. "</configuration></execution></executions></plugin>"
end

local function pom(body, properties)
  return "<project><properties>" .. (properties or "") .. "</properties><build><plugins>" .. body
         .. "</plugins></build></project>"
end

local function reads(name, text, wanted)
  return { name = name, check = function() return expect.equal(frontend_pom.node_pins(text), wanted) end }
end

return {
  reads("reads a literal nodeVersion", pom(plugin("<nodeVersion>v9.11.1</nodeVersion>")),
        { { version = "v9.11.1" } }),
  reads("resolves a property the pom defines",
        pom(plugin("<nodeVersion>${node.version}</nodeVersion>"), "<node.version> v22.15.0 </node.version>"),
        { { version = "v22.15.0" } }),
  reads("keeps a property the pom does not define", pom(plugin("<nodeVersion>${node.version}</nodeVersion>")),
        { { unresolved = "${node.version}" } }),
  reads("ignores another plugin's nodeVersion",
        pom("<plugin><artifactId>other-plugin</artifactId><configuration><nodeVersion>v9.0.0</nodeVersion>"
            .. "</configuration></plugin>"), {}),
  reads("ignores a commented-out plugin", pom("<!-- " .. plugin("<nodeVersion>v9.0.0</nodeVersion>") .. " -->"), {}),
  reads("ignores a plugin run in another directory",
        pom(plugin("<nodeVersion>v9.0.0</nodeVersion><workingDirectory>src/main/web</workingDirectory>")), {}),
  reads("reads a plugin run in the pom's own directory",
        pom(plugin("<nodeVersion>v24.0.0</nodeVersion><workingDirectory>${basedir}</workingDirectory>")),
        { { version = "v24.0.0" } }),
  reads("lists one version once", pom(plugin("<nodeVersion>v24.0.0</nodeVersion>")
                                       .. plugin("<nodeVersion>v24.0.0</nodeVersion>")),
        { { version = "v24.0.0" } }),
  reads("reads no pom as none", nil, {}),
}
