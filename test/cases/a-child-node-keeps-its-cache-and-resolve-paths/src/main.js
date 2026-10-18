const { execFileSync } = require("node:child_process");
const { join } = require("node:path");
process.stdout.write(execFileSync(process.execPath, [join(__dirname, "child.js")]));
