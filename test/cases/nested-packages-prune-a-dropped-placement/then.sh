sed -i.bak '/nestedPackages/,$d' daukle.toml && rm daukle.toml.bak
printf 'import { existsSync } from "node:fs"; console.log(existsSync("src/legacy/package.json") ? "still placed" : "pruned");\n' > src/main.js
