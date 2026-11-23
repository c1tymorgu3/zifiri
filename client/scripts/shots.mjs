#!/usr/bin/env node
/**
 * Screenshots of the built client, at the exact viewport the design is judged at.
 *
 * Chrome's `--screenshot` flag sizes the *window*, and in `--headless=new` the
 * window is ~78px taller than the viewport it renders — a PNG taken that way
 * shows a layout nobody sees, with the composer sitting 78px too high. This
 * drives the DevTools protocol instead: the viewport is set explicitly, the page
 * is allowed to settle, and the capture is 1:1.
 *
 *   node scripts/shots.mjs [outDir] [tag] [--all]
 *
 * Serves nothing: point ZF_URL at a running preview (default :4000).
 */
import { spawn } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

const CHROME = process.env.ZF_CHROME ?? 'C:/Program Files/Google/Chrome/Application/chrome.exe';
const BASE = process.env.ZF_URL ?? 'http://127.0.0.1:4000';
const OUT = resolve(process.argv[2] ?? 'docs/shots');
const TAG = process.argv[3] ?? 'shot';
const ALL = process.argv.includes('--all');
const PORT = 9333;

const VIEWPORTS = [
  { name: 'desktop', width: 1280, height: 860, mobile: false },
  { name: 'mobile', width: 390, height: 844, mobile: true },
];

const SHOTS = ALL
  ? [
      { suffix: '', query: '' },
      { suffix: '-messages', query: '&surface=messages' },
      { suffix: '-listings', query: '&surface=listings' },
    ]
  : [{ suffix: '', query: '' }];

const sleep = (ms) => new Promise((done) => setTimeout(done, ms));

async function firstPage() {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    try {
      const response = await fetch(`http://127.0.0.1:${PORT}/json`);
      const pages = (await response.json()).filter((entry) => entry.type === 'page');
      if (pages.length > 0) return pages[0].webSocketDebuggerUrl;
    } catch {
      // Chrome is still starting.
    }
    await sleep(150);
  }
  throw new Error('chrome did not open a debugging port');
}

function session(url) {
  const socket = new WebSocket(url);
  const pending = new Map();
  let id = 0;
  const ready = new Promise((done, fail) => {
    socket.addEventListener('open', () => done());
    socket.addEventListener('error', fail);
  });
  socket.addEventListener('message', (event) => {
    const message = JSON.parse(event.data);
    const waiting = pending.get(message.id);
    if (waiting === undefined) return;
    pending.delete(message.id);
    if (message.error) waiting.reject(new Error(message.error.message));
    else waiting.done(message.result);
  });
  return {
    ready,
    send(method, params = {}) {
      id += 1;
      const current = id;
      return new Promise((done, reject) => {
        pending.set(current, { done, reject });
        socket.send(JSON.stringify({ id: current, method, params }));
      });
    },
    close: () => socket.close(),
  };
}

const chrome = spawn(CHROME, [
  '--headless=new',
  '--disable-gpu',
  '--hide-scrollbars',
  '--force-device-scale-factor=1',
  `--remote-debugging-port=${PORT}`,
  `--user-data-dir=${join(process.env.TEMP ?? '/tmp', `zf-shots-${process.pid}`)}`,
  '--no-first-run',
  '--no-default-browser-check',
  'about:blank',
], { stdio: 'ignore' });

try {
  const tab = session(await firstPage());
  await tab.ready;
  mkdirSync(OUT, { recursive: true });

  for (const view of VIEWPORTS) {
    for (const shot of SHOTS) {
      await tab.send('Emulation.setDeviceMetricsOverride', {
        width: view.width,
        height: view.height,
        deviceScaleFactor: 1,
        mobile: view.mobile,
      });
      await tab.send('Page.navigate', { url: `${BASE}/?demo=1${shot.query}` });
      await sleep(1200);
      const { data } = await tab.send('Page.captureScreenshot', { format: 'png' });
      const file = join(OUT, `${TAG}-${view.name}${shot.suffix}.png`);
      writeFileSync(file, Buffer.from(data, 'base64'));
      console.log(`${file}  ${view.width}x${view.height}`);
    }
  }

  tab.close();
} finally {
  chrome.kill();
}
