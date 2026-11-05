import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";

const git = (...args) => execFileSync("git", args, { cwd: "..", encoding: "utf8" });
const listed = git("status", "--porcelain", "--untracked-files=all", "--", "web/node_modules", "web/package.json");
console.log(listed === "" ? "git lists no placed entry" : "git lists: " + listed.trim());
const exclude = readFileSync(git("rev-parse", "--git-path", "info/exclude").trim().replace(/^(?![A-Za-z]:|\/)/, "../"), "utf8");
for (const line of exclude.split(/\r?\n/)) if (line.startsWith("/web/")) console.log(line);
