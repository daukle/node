const { mkdirSync, writeFileSync } = require("node:fs");
mkdirSync("dist", { recursive: true });
writeFileSync("dist/index.js", "module.exports = \"built\";\n");
process.stdout.write("built dist, no newline");
