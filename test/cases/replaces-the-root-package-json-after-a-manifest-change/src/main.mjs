import { readFileSync } from "node:fs";
console.log("dependencies:", Object.keys(JSON.parse(readFileSync("package.json")).dependencies).join(" "));
