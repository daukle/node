const fs = require("fs");
const path = require("path");
const fsPromises = require("fs/promises");
const sys = require("sys");
console.log("builtins", fs === require("node:fs"), path === require("node:path"), fsPromises === require("node:fs/promises"), sys === require("node:util"));
