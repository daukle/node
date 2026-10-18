import { existsSync } from "node:fs";
console.log(existsSync("daukle.toml") ? "cwd is the package root" : "cwd is " + process.cwd());
