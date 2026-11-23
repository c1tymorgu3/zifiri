#!/usr/bin/env node
// Client-side proof of work: how long a 20-bit proof takes in a browser-shaped
// JavaScript runtime, and what the same proof costs on a slower CPU.
//
//   node scripts/measure/pow_browser.js
//   node scripts/measure/pow_browser.js --trials 7 --bits 20
//   node scripts/measure/pow_browser.js --help
//
// What is measured is the real thing, not a model of it:
//
//   * the message is the one the server verifies — `challenge_id` (16 bytes)
//     followed by `payload_hash` (32 bytes) followed by the nonce as an
//     unsigned 64-bit big-endian integer, hashed with SHA-256, accepted when
//     the digest has `bits` leading zero bits (`lib/zifiri/pow.ex`);
//   * the hash is `@noble/hashes`' SHA-256 — the same library the browser
//     client ships, from `client/node_modules`;
//   * the clock is `process.hrtime.bigint()`, wall time, not a hash count.
//
// The three scenarios are the same loop with a slower CPU simulated the only
// way that keeps the measurement honest: the identical digest is computed
// `factor` times per nonce. A CPU that is four times slower spends four times
// as long on the same hash and gets the same answer, so `factor = 4` is what
// the loop costs there — no artificial sleep, no fudged multiplier applied to
// the result. The proof still has to be found, and the number printed is the
// wall time it took.
//
// PoW is a geometric process, so one trial says little: each scenario runs
// `--trials` independent challenges (fresh id and payload hash) and reports
// min / median / max. The 20-bit claim in `lib/zifiri/pow.ex` ("roughly a
// quarter second in a browser worker") is what the desktop verdict tests.

const path = require("node:path");
const fs = require("node:fs");
const { pathToFileURL } = require("node:url");

const HELP = `
pow_browser.js — 20-bit proof-of-work time in Node, at three CPU speeds.

Usage:
  node scripts/measure/pow_browser.js [options]

Options:
  --bits N      leading zero bits required (default 20)
  --trials N    independent challenges per scenario (default 5)
  --help, -h    print this text and exit

Scenarios:
  1x  desktop, as measured
  4x  the same loop on a CPU four times slower (digest computed 4x per nonce)
  8x  the same loop on a CPU eight times slower

Output: attempts and milliseconds (min/median/max) per scenario, a JSON report
in scripts/measure/results/, and a verdict on the "~250 ms at 20 bits" claim
for the desktop scenario.
`;

function parseArgs(argv) {
  const opts = { bits: 20, trials: 5 };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--help" || a === "-h") {
      process.stdout.write(HELP);
      process.exit(0);
    } else if (a === "--bits" || a.startsWith("--bits=")) {
      opts.bits = Number(a.includes("=") ? a.split("=")[1] : argv[++i]);
    } else if (a === "--trials" || a.startsWith("--trials=")) {
      opts.trials = Number(a.includes("=") ? a.split("=")[1] : argv[++i]);
    } else {
      process.stderr.write(`unknown argument: ${a}\n${HELP}`);
      process.exit(2);
    }
  }
  if (!Number.isInteger(opts.bits) || opts.bits < 1 || opts.bits > 40) {
    throw new Error(`--bits must be an integer in 1..40, got ${opts.bits}`);
  }
  if (!Number.isInteger(opts.trials) || opts.trials < 1) {
    throw new Error(`--trials must be a positive integer, got ${opts.trials}`);
  }
  return opts;
}

function leadingZeroBits(bytes) {
  let bits = 0;
  for (let i = 0; i < bytes.length; i++) {
    const byte = bytes[i];
    if (byte === 0) {
      bits += 8;
      continue;
    }
    bits += Math.clz32(byte) - 24;
    break;
  }
  return bits;
}

// A challenge is the 48-byte prefix the server hashes: `challengeId` (16 B)
// followed by `payloadHash` (32 B). The nonce is appended per attempt.
function makeChallenge() {
  const prefix = new Uint8Array(48);
  crypto.getRandomValues(prefix.subarray(0, 16));
  crypto.getRandomValues(prefix.subarray(16, 48));
  return prefix;
}

// Every scenario solves the *same* challenges. That is what makes the three
// rows comparable: the number of attempts is identical, so the only thing the
// milliseconds can differ by is the per-hash cost.
function solve(sha256, bits, factor, prefix) {
  const message = new Uint8Array(56);
  message.set(prefix, 0);
  const view = new DataView(message.buffer);

  const started = process.hrtime.bigint();
  let attempts = 0;

  for (let nonce = 0; ; nonce++) {
    // The nonce is a u64be; writing the two 32-bit halves is what a client
    // does. `setBigUint64` costs a BigInt allocation per attempt — 5x the hash
    // itself — and no client pays that.
    const hi = Math.floor(nonce / 4294967296);
    const lo = nonce >>> 0;
    // The whole attempt body runs `factor` times: that is what a
    // `factor`-times-slower CPU executes for the same nonce. Only the first
    // digest is checked — it is the same digest every time.
    let digest;
    for (let k = 0; k < factor; k++) {
      view.setUint32(48, hi, false);
      view.setUint32(52, lo, false);
      digest = sha256(message);
    }
    attempts++;
    if (leadingZeroBits(digest) >= bits) break;
    if (attempts > 50_000_000) throw new Error("no solution within 50M nonces");
  }

  const ms = Number(process.hrtime.bigint() - started) / 1e6;
  return { attempts, ms };
}

function median(values) {
  const s = [...values].sort((a, b) => a - b);
  const mid = Math.floor(s.length / 2);
  return s.length % 2 ? s[mid] : (s[mid - 1] + s[mid]) / 2;
}

function runScenario(sha256, { bits, factor }, challenges) {
  const runs = challenges.map((prefix) => solve(sha256, bits, factor, prefix));
  const ms = runs.map((r) => r.ms);
  const attempts = runs.map((r) => r.attempts);
  return {
    factor,
    trials: challenges.length,
    attempts: attempts.slice(),
    ms_min: Math.min(...ms),
    ms_median: median(ms),
    ms_max: Math.max(...ms),
    ms_mean: ms.reduce((a, b) => a + b, 0) / ms.length,
    attempts_mean: attempts.reduce((a, b) => a + b, 0) / attempts.length,
    attempts_min: Math.min(...attempts),
    attempts_max: Math.max(...attempts),
    hashes_per_s: (attempts.reduce((a, b) => a + b, 0) * factor) /
      (ms.reduce((a, b) => a + b, 0) / 1000),
  };
}

function fmt(n, digits = 1) {
  return Number(n).toFixed(digits);
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));

  const noblePath = path.join(__dirname, "../../client/node_modules/@noble/hashes/sha2.js");
  const { sha256 } = await import(pathToFileURL(noblePath).href);

  process.stdout.write(
    `pow_browser: ${opts.bits} bits, ${opts.trials} trials per scenario, ` +
      `node ${process.version}, ${require("node:os").cpus()[0].model}\n\n`
  );

  // A warm-up run is discarded: V8 has to optimise the hash loop before the
  // first number means anything. Eight bits is enough to trigger that.
  solve(sha256, 8, 1, makeChallenge());

  const scenarios = [
    { label: "desktop (1x)", factor: 1 },
    { label: "phone, 4x slower", factor: 4 },
    { label: "phone, 8x slower", factor: 8 },
  ];

  const challenges = Array.from({ length: opts.trials }, makeChallenge);

  const results = {};
  for (const s of scenarios) {
    process.stdout.write(`running ${s.label} ... `);
    results[s.label] = runScenario(sha256, { ...opts, factor: s.factor }, challenges);
    const r = results[s.label];
    process.stdout.write(`${fmt(r.ms_median)} ms median\n`);
  }

  process.stdout.write(
    "\nscenario             attempts(mean)   ms min   ms median   ms max   ms mean   Mhash/s\n"
  );
  for (const s of scenarios) {
    const r = results[s.label];
    process.stdout.write(
      `${s.label.padEnd(20)} ${fmt(r.attempts_mean, 0).padStart(14)} ` +
        `${fmt(r.ms_min).padStart(8)} ${fmt(r.ms_median).padStart(11)} ` +
        `${fmt(r.ms_max).padStart(8)} ${fmt(r.ms_mean).padStart(9)} ` +
        `${fmt(r.hashes_per_s / 1e6, 2).padStart(9)}\n`
    );
  }

  const desktop = results["desktop (1x)"];
  const CLAIM_MS = 250;
  const passed = desktop.ms_median <= CLAIM_MS;

  process.stdout.write(
    `\nclaim: 20 bits ~ 250 ms in a browser worker (lib/zifiri/pow.ex)\n` +
      `desktop median ${fmt(desktop.ms_median)} ms → ${passed ? "PASS" : "FAIL"}\n`
  );

  const dir = path.join(__dirname, "results");
  fs.mkdirSync(dir, { recursive: true });
  const stamp = new Date().toISOString().replace(/[^0-9T]/g, "");
  const file = path.join(dir, `pow-${stamp}.json`);
  fs.writeFileSync(
    file,
    JSON.stringify(
      {
        kind: "pow-browser",
        measured_at: new Date().toISOString(),
        bits: opts.bits,
        trials: opts.trials,
        node: process.version,
        cpu: require("node:os").cpus()[0].model,
        scenarios: results,
        claim_ms: CLAIM_MS,
        passed,
      },
      null,
      2
    ) + "\n"
  );
  process.stdout.write(`report ${file}\n`);

  process.exit(passed ? 0 : 1);
}

main().catch((err) => {
  process.stderr.write(`${err.stack || err}\n`);
  process.exit(2);
});
