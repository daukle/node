import { readFileSync } from 'node:fs';

const manifest = JSON.parse(readFileSync('package.json', 'utf8'));
console.log(JSON.stringify(manifest.engines));
console.log(process.version);
