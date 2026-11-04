import { readFileSync } from 'node:fs';

const manifest = JSON.parse(readFileSync('package.json', 'utf8'));
console.log(JSON.stringify(manifest.browserslist));
console.log(JSON.stringify(manifest['lint-staged']));
console.log(manifest.sideEffects);
