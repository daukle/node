import { mkdirSync, writeFileSync } from 'node:fs';

mkdirSync('out', { recursive: true });
writeFileSync('out/b.txt', 'b');
writeFileSync('out/a.txt', 'a');
writeFileSync('out/.hidden.txt', 'h');
