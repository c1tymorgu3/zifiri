#!/usr/bin/env node
// Screenshots of the built client, the same way a person would look at it:
// Chrome headless, a real window size, a real URL. Two sizes per round.
import { execFileSync } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import { join, resolve } from 'node:path';

const CHROME = 'C:/Program Files/Google/Chrome/Application/chrome.exe';
const OUT = resolve(process.argv[2] ?? 'docs/shots');
const TAG = process.argv[3] ?? 'r1';
const BASE = process.env.ZF_URL ?? 'http://127.0.0.1:4000';

mkdirSync(OUT, { recursive: true });

const shots = [
  { name: `${TAG}-desktop`, size: '1280,860', url: `${BASE}/?demo=1` },
  { name: `${TAG}-mobile`, size: '390,844', url: `${BASE}/?demo=1` },
  ...(process.argv.includes('--all')
    ? [
        { name: `${TAG}-desktop-messages`, size: '1280,860', url: `${BASE}/?demo=1&surface=messages` },
        { name: `${TAG}-desktop-listings`, size: '1280,860', url: `${BASE}/?demo=1&surface=listings` },
        { name: `${TAG}-mobile-messages`, size: '390,844', url: `${BASE}/?demo=1&surface=messages` },
        { name: `${TAG}-mobile-listings`, size: '390,844', url: `${BASE}/?demo=1&surface=listings` },
      ]
    : []),
];

for (const shot of shots) {
  const file = join(OUT, `${shot.name}.png`);
  execFileSync(CHROME, [
    '--headless=new',
    '--disable-gpu',
    '--hide-scrollbars',
    '--force-device-scale-factor=1',
    '--virtual-time-budget=2500',
    `--window-size=${shot.size}`,
    `--screenshot=${file}`,
    shot.url,
  ], { stdio: 'ignore' });
  console.log(file);
}
