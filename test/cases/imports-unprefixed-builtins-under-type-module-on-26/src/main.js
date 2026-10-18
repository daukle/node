import fs from "fs";
import path from "path";
import fsPromises from "fs/promises";
import prefixedFs from "node:fs";
import prefixedPath from "node:path";
import prefixedFsPromises from "node:fs/promises";

console.log("builtins", fs === prefixedFs, path === prefixedPath, fsPromises === prefixedFsPromises);
