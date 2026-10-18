import { existsSync } from "node:fs";

if (!existsSync("dist/a.js")) {
  console.error("dist/a.js was not written");
  process.exit(1);
}
console.log("compiled");
