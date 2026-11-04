import { existsSync } from 'node:fs';

console.log(existsSync('out') ? 'kept' : 'gone');
