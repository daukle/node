import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const [packageName, binName, ...rest] = process.argv.slice(2);
const packageRoot = join(here, "node_modules", packageName);

let manifest;
try {
  manifest = JSON.parse(readFileSync(join(packageRoot, "package.json"), "utf8"));
} catch (cause) {
  throw new Error(`"${packageName}" is not installed, so it has no command to run`, { cause });
}

const bin = manifest.bin;
const wanted = binName || packageName;
let target;
if (typeof bin === "string") {
  if (binName && binName !== packageName) {
    throw new Error(`"${packageName}" publishes one command and it is not "${binName}"`);
  }
  target = bin;
} else if (bin && typeof bin === "object") {
  target = bin[wanted];
  if (typeof target !== "string") {
    const offered = Object.keys(bin).sort().join(", ");
    throw new Error(
      `"${packageName}" publishes no command called "${wanted}": set "binName" to one of ${offered}`,
    );
  }
} else {
  throw new Error(`"${packageName}" publishes no command, so there is nothing to run`);
}

// The bin reads its own name and arguments out of argv, exactly as it would
// behind npm's shim, so argv is rewritten before it is imported rather than
// after it has already read the wrong one.
const resolved = resolve(packageRoot, target);
process.argv = [process.argv[0], resolved, ...rest];
await import(pathToFileURL(resolved).href);
