import { existsSync } from "node:fs";
console.log(existsSync("where.mjs") ? "cwd is a/b" : "cwd is " + process.cwd());
