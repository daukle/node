import { existsSync, readFileSync } from "node:fs";
console.log("in web", existsSync("node_modules/semver"), JSON.parse(readFileSync("package.json")).dependencies.semver);
console.log("at the project root", existsSync("../node_modules"), existsSync("../package.json"));
