#!/usr/bin/env node
// Measures the built bundle and enforces the 100 KiB (gzip) budget.
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { gzipSync } from 'node:zlib';

const ROOT = fileURLToPath(new URL('..', import.meta.url));
const DIST = join(ROOT, 'dist');
const BUDGET = 100 * 1024;

if (!existsSync(DIST)) {
  console.error('dist/ not found. Run `npm run build` first.');
  process.exit(1);
}

function walk(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    return entry.isDirectory() ? walk(path) : [path];
  });
}

const assets = walk(DIST).filter((path) => /\.(js|css)$/.test(path));
if (assets.length === 0) {
  console.error('no JS/CSS assets in dist/. Run `npm run build` first.');
  process.exit(1);
}

const kib = (bytes) => `${(bytes / 1024).toFixed(1)} KiB`;
let jsGzip = 0;
let jsRaw = 0;

console.log('asset                              raw       gzip');
console.log('--------------------------------------------------');
for (const path of assets.sort()) {
  const raw = readFileSync(path);
  const gzip = gzipSync(raw, { level: 9 }).length;
  if (path.endsWith('.js')) {
    jsGzip += gzip;
    jsRaw += raw.length;
  }
  const label = relative(DIST, path).replaceAll('\\', '/');
  console.log(`${label.padEnd(34)} ${kib(raw.length).padStart(9)} ${kib(gzip).padStart(9)}`);
}

console.log('--------------------------------------------------');
console.log(`JS total${' '.repeat(26)} ${kib(jsRaw).padStart(9)} ${kib(jsGzip).padStart(9)}`);
console.log(`Budget: ${kib(BUDGET)} gzip for JS.`);

if (jsGzip > BUDGET) {
  console.error(`FAIL: JS gzip ${kib(jsGzip)} exceeds ${kib(BUDGET)}.`);
  process.exit(1);
}
console.log(`PASS: ${kib(jsGzip)} gzip (${((jsGzip / BUDGET) * 100).toFixed(1)}% of budget).`);
