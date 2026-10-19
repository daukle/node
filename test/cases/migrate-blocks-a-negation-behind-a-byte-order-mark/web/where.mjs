import { existsSync } from "node:fs";
console.log(existsSync("where.mjs") ? "cwd is web" : "cwd is " + process.cwd());
