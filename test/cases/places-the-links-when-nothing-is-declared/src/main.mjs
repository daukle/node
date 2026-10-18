import { existsSync } from "node:fs";
console.log("node_modules", existsSync("node_modules"), "package.json", existsSync("package.json"));
