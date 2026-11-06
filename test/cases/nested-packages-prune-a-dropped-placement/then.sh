sed -i '/nestedPackages/,$d' daukle.toml
printf 'import { existsSync } from "node:fs"; console.log(existsSync("src/legacy/package.json") ? "still placed" : "pruned");\n' > src/main.js
