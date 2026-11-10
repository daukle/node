const { mkdirSync, writeFileSync } = require("node:fs");
const ms = require("ms");
mkdirSync("dist", { recursive: true });
writeFileSync("dist/index.js", `module.exports = ${ms("1m")};\n`);
