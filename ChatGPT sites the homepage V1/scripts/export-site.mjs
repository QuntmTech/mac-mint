import { cpSync, rmSync, existsSync } from 'node:fs';
const out = new URL('../out/', import.meta.url);
const site = new URL('../site/', import.meta.url);
if (!existsSync(new URL('index.html', out))) throw new Error('Static export did not produce index.html');
rmSync(site, { recursive: true, force: true });
cpSync(out, site, { recursive: true });
console.log('Ready-to-serve HTML, CSS, JS and assets copied to site/.');
