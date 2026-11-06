local SCRIPT_NAME = "__daukle_npm__.mjs"

--- Runs npm-cli.js in this process after putting this node's directory first on PATH, because npm
--- resolves the `node` of every lifecycle script and node-gyp child through PATH and would
--- otherwise run the host's node, or none (D-236). Its arguments are npm-cli.js and npm's own.
local SCRIPT = [==[
import { delimiter, dirname } from "node:path";
import { pathToFileURL } from "node:url";

const [npmCli, ...npmArguments] = process.argv.slice(2);
const pathName = Object.keys(process.env).find((name) => name.toUpperCase() === "PATH") ?? "PATH";
const inherited = process.env[pathName];
process.env[pathName] = inherited ? dirname(process.execPath) + delimiter + inherited : dirname(process.execPath);
process.argv = [process.argv[0], npmCli, ...npmArguments];
await import(pathToFileURL(npmCli).href);
]==]

return { SCRIPT_NAME = SCRIPT_NAME, SCRIPT = SCRIPT }
