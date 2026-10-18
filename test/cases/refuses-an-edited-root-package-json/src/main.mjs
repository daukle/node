import { existsSync, readFileSync } from "node:fs";
console.log(existsSync("node_modules/semver"), JSON.parse(readFileSync("package.json")).dependencies.semver);
