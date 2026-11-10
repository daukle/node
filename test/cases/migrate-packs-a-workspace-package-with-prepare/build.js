const { mkdirSync, writeFileSync } = require("node:fs");
require("debug");
mkdirSync("dist", { recursive: true });
writeFileSync("dist/index.js", "module.exports = \"built root\";\n");
