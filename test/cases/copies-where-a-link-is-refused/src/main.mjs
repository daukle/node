import { existsSync, readFileSync } from "node:fs";
console.log("copied", existsSync("node_modules/.daukle-copy"), existsSync("node_modules/semver"),
  JSON.parse(readFileSync("package.json")).dependencies.semver);
