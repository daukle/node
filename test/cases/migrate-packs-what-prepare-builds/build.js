const { mkdirSync, writeFileSync } = require("node:fs");
mkdirSync("dist", { recursive: true });
writeFileSync("dist/index.js", "module.exports = \"built\";\n");
console.log("built dist");
