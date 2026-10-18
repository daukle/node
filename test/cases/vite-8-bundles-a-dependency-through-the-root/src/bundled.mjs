import { existsSync } from "node:fs";

if (!existsSync("dist/index.html")) {
  console.error("dist/index.html was not written");
  process.exit(1);
}
console.log("bundled");
