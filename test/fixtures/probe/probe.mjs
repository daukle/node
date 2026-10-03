// The suite's reason to exist. Three of the resolver's four guards return a
// WORKING module when they are wrong, so nothing here asserts that a module
// loaded: every specifier is compared against what node resolves natively from
// a twin of the same tree, and against a control in which the resolver is
// absent and every specifier must fail.
import { createRequire } from "node:module";
import { execFileSync } from "node:child_process";
import { cpSync, mkdirSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { basename, dirname, join, resolve as resolvePath } from "node:path";

import { SPECIFIERS, report } from "./report.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const projectRoot = resolvePath(here, "..", "..");
const modules = join(projectRoot, "fixtures", "modules", "node_modules");
const derived = join(projectRoot, "build", "daukle", "node");
const nativeRoot = join(projectRoot, "native");
// Outside the project root on purpose: the resolver's gate is a test on the
// project a module was imported from, so a project inside this one would not
// exercise it at all.
const unrelatedRoot = resolvePath(projectRoot, "..", "unrelated-" + basename(projectRoot));

const requireFromHere = createRequire(import.meta.url);
const failures = [];

function check(what, condition, detail) {
  if (!condition) failures.push(what + ": " + detail);
}

function stageTrees() {
  cpSync(modules, join(derived, "node_modules"), { recursive: true });
  cpSync(modules, join(nativeRoot, "node_modules"), { recursive: true });
  cpSync(join(here, "report.mjs"), join(nativeRoot, "report.mjs"));

  const unrelatedPackage = join(unrelatedRoot, "node_modules", "hoisted");
  mkdirSync(unrelatedPackage, { recursive: true });
  writeFileSync(join(unrelatedPackage, "package.json"),
                '{ "name": "hoisted", "version": "9.9.9", "main": "index.js" }\n');
  writeFileSync(join(unrelatedPackage, "index.js"),
                'module.exports = { version: "9.9.9" };\n');
  writeFileSync(join(unrelatedRoot, "report.mjs"),
                'import { createRequire } from "node:module";\n'
                + 'process.stdout.write(createRequire(import.meta.url)("hoisted").version);\n');
  writeFileSync(join(unrelatedRoot, "spawn.mjs"),
                'import { execFileSync } from "node:child_process";\n'
                + 'import { fileURLToPath } from "node:url";\n'
                + 'import { dirname, join } from "node:path";\n'
                + 'const here = dirname(fileURLToPath(import.meta.url));\n'
                + 'process.stdout.write(execFileSync(process.execPath,'
                + ' [join(here, "report.mjs")], { encoding: "utf8" }));\n');
}

function withoutResolver() {
  const environment = { ...process.env };
  delete environment.NODE_OPTIONS;
  return environment;
}

function runNode(script, environment, workingDirectory) {
  return execFileSync(process.execPath, [script, "--print"],
                      { env: environment, encoding: "utf8", cwd: workingDirectory });
}

stageTrees();

const underResolver = await report();
const native = JSON.parse(runNode(join(nativeRoot, "report.mjs"), withoutResolver(), projectRoot));
const control = JSON.parse(runNode(join(here, "report.mjs"), withoutResolver(), projectRoot));

for (const specifier of SPECIFIERS) {
  for (const system of ["cjs", "esm"]) {
    check("resolution", underResolver[specifier][system] === native[specifier][system],
          `${specifier} (${system}) loaded ${underResolver[specifier][system]},`
          + ` node natively loads ${native[specifier][system]}`);
    check("control", control[specifier][system].startsWith("ERROR"),
          `${specifier} (${system}) loaded ${control[specifier][system]} with no resolver,`
          + " so this suite is measuring an ancestor directory's node_modules");
  }
}

check("absent", underResolver["no-such-package"].cjs.startsWith("ERROR"),
      "a package that is not installed resolved anyway");

const imported = await import("dual");
check("dual", imported.branch === "import",
      `importing "dual" gave the ${imported.branch} branch`);
check("dual", requireFromHere("dual").branch === "require",
      `requiring "dual" gave the ${requireFromHere("dual").branch} branch`);

check("nested", requireFromHere("dependant").hoisted.version === "1.0.0",
      `"dependant" got hoisted ${requireFromHere("dependant").hoisted.version},`
      + " not the 1.0.0 in its own node_modules");
check("hoisted", requireFromHere("hoisted").version === "2.0.0",
      `"hoisted" resolved to ${requireFromHere("hoisted").version}`);

check("inherited", (process.env.NODE_OPTIONS || "").includes("__daukle_resolver__.mjs"),
      "NODE_OPTIONS carries no resolver, so no descendant would get one");

const direct = runNode(join(unrelatedRoot, "report.mjs"), process.env, unrelatedRoot).trim();
check("unrelated", direct === "9.9.9",
      `an unrelated project under the inherited NODE_OPTIONS got hoisted ${direct}`);

const grandchild = execFileSync(process.execPath, [join(unrelatedRoot, "spawn.mjs")],
                                { env: process.env, encoding: "utf8",
                                  cwd: unrelatedRoot }).trim();
check("unrelated", grandchild === "9.9.9", `an unrelated grandchild got hoisted ${grandchild}`);

if (failures.length > 0) {
  for (const failure of failures) process.stderr.write(failure + "\n");
  process.exitCode = 1;
} else {
  process.stdout.write(`every specifier agrees with node on ${process.version}`
                       + ` (${SPECIFIERS.length} checked)\n`);
}
