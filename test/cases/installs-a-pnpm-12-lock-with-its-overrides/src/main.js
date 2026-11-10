const { createRequire } = require("module");
const debug = require("debug");
const fromDebug = createRequire(require.resolve("debug"));
console.log(typeof debug === "function" ? "debug loaded" : "no debug");
console.log("ms " + fromDebug("ms/package.json").version);
