# Robustness measurements

Every number in this file is the **executed** output of a script under
`scripts/measure/`. If something was not measured, the table says "not
measured" and gives the reason; an estimate, a design target or an "approximate"
number does not appear here.

The measurements were taken before the showcase (README) was written: every
number in the README must come from here, and every number here must be
reproducible.

## Environment

| | |
|---|---|
| Hardware | 13th Gen Intel Core i3-13100F, Windows 11 |
| Erlang / Elixir | OTP 29 (erts 17.1.1) / Elixir 1.20.5 |
| Node | v24.16.0 |
| `@noble/hashes` | 2.4.0 (`client/node_modules`) |
| Database | SQLite, `ecto_sqlite3`; `secure_delete=ON`, `journal_mode=WAL`, `synchronous=NORMAL` |
| Environment | `MIX_ENV=test`, `pool_size` 8 |

All scripts support `--help`. The measurement database is deleted after every
run (`_build/test/zifiri_load.db*`); no file is left under `_build/test/` after
a measurement.

## Summary

| # | Measurement | Command | Number | Threshold | Result |
|---|---|---|---|---|---|
| 1 | Publish latency, 200 concurrent writes, p95 | `publish_latency.exs` | **50.4 ms** (8 runs; 39.7–110.9) | < 2,000 ms | **PASSED** |
| 2 | Publish latency, p50 | same | 35.0–48.7 ms | informational | — |
| 3 | Publish latency, p99 | same | 59.0–135.9 ms | informational | — |
| 4 | Deletion, 50 listings, `erase_many/1` duration | `erase_latency.exs` | **8.0–11.7 ms** | ≤ 5,000 ms | **PASSED** |
| 5 | Deletion, moment the canary vanishes from file/WAL | same | **7–10 ms** | ≤ 5,000 ms | **PASSED** |
| 6 | Deletion, 5.2 MB file (50 canaries + 5,000 filler) | `erase_latency.exs --filler 5000` | **45.4–59.1 ms** (4 runs) | ≤ 5,000 ms | **PASSED** |
| 7 | PoW 20 bit, desktop (Node) | `pow_browser.js` | **1,838.8 ms** median (431.7–4,338.4) | ≈ 250 ms (`pow.ex` claim) | **FAILED** |
| 8 | PoW 20 bit, 4× slower CPU (simulated) | same | **7,563.9 ms** median | informational | — |
| 9 | PoW 20 bit, 8× slower CPU (simulated) | same | **13,338.5 ms** median | informational | — |
| 10 | Identity line length (`zifiri1` + 40 bytes base32) | `identity_line.exs`, `node -e` | **71 characters** | 71 | **PASSED** |

## 1–3. Publish latency (200 concurrent writes)

```
MIX_ENV=test mix run --no-start scripts/measure/publish_latency.exs
```

200 writes start at the same instant; each does `POST /api/listings` with its
own owner key and its own 8-bit proof. The measured time is TCP connection +
proof check + body check + insert + response. The 8-bit difficulty is pinned so
that server-side latency is what is measured — the client's real 20-bit cost is
rows 7–9. A warm-up of 10 writes is discarded.

Eight runs (each with 200/200 `HTTP 201` and a single response size:
**16,384 bytes**):

| run | p50 | p95 | p99 | max |
|---|---|---|---|---|
| 1 | 31.1 | 39.7 | 69.9 | 91.2 |
| 2 | 36.2 | 48.3 | 63.8 | 89.0 |
| 3 | 42.5 | 53.1 | 69.1 | 95.9 |
| 4 | 48.7 | 110.9 | 135.9 | 155.1 |
| 5 | 35.3 | 50.9 | 68.2 | 86.5 |
| 6 | 48.0 | 63.4 | 89.1 | 93.4 |
| 7 | 35.0 | 47.3 | 59.0 | 117.7 |
| 8 | 37.5 | 49.9 | 75.7 | 112.3 |

Median p95 **50.4 ms**, worst run **110.9 ms**. The threshold is 2,000 ms; the
worst run is 18× under it.

The spread between runs (~3×) is real, and all eight are listed here so that a
single run is not written down as "the number". The number of completed writes,
the table row count (200) and the fixed response size are verified in every
run; the script FAILS if any of them does not hold.

Raw output (run 5):

```
                  min       p50       p95       p99       max       mean      (ms)
write_ms          4.0       35.3      50.9      68.2      86.5      34.9      ms
created       200/200 (HTTP 201)
failed        0
rows in table 200
response size [16384] bytes (fixed-size check)
wall clock    100 ms for the whole batch
```

## 4–6. Deletion duration and proof on disk

```
MIX_ENV=test mix run --no-start scripts/measure/erase_latency.exs
MIX_ENV=test mix run --no-start scripts/measure/erase_latency.exs --filler 5000
```

50 listings are written; each has a separate, random, unique canary in its
**body** (inside the envelope) and in its **title** (unencrypted). The script
first scans the database file and the `-wal` file — the canary **must** be found
there, otherwise a post-deletion scan proves nothing — then measures
`Zifiri.Vanish.erase_many/1`, then scans again and repeats the scan until the
canaries are gone.

Small database (main file 4 KB + 1.0 MB WAL; 45 KB after deletion, 50 listings):

```
written        50 rows in 29 ms
canary before  body %{total: 296, wal: 296, db: 0, found_in_wal: 50 of 50}
erase_many     {:ok, 50} in 9.6 ms
canary after   body %{total: 0, wal: 0, db: 0, found_in_db: 0, found_in_wal: 0}
time to absent 9 ms
rows after     0
freelist       0 pages   page_count 11
wal file       0 bytes
```

Six runs: `erase_many` **8.0 / 8.3 / 8.3 / 9.6 / 10.8 / 11.7 ms**. The moment
the canary vanishes in the last three runs is **7 / 9 / 10 ms**; the 26–27 ms
seen in the first runs was the scanner's own cost (the file was read 50 times
for 50 canaries) and dropped once the script was changed to a single read — what
is measured now is the deletion, not the scan. Before deletion the canary was
found in 50/50 listings, **296** times in total (several copies inside WAL
frames); afterwards **0**. Table rows 0, `freelist_count` 0, `-wal` 0 bytes.

Real-sized file (5.2 MB, 1,258 pages, 50 canaries + 5,000 filler listings; the
filler rows are not deleted and stay in place):

```
canary before  body %{total: 50, db: 50, wal: 0, found_in_db: 50 of 50}
erase_many     {:ok, 50} in 52.8 ms
canary after   body %{total: 0, db: 0, wal: 0}
time to absent 52 ms
rows after     5000   (filler; the 50 canary rows are gone)
freelist       0 pages   page_count 1258
```

Four runs: `erase_many` **45.4 / 52.8 / 56.0 / 59.1 ms**; the moment the canary
vanishes in the same runs is **52 / 59 ms** (the 45.4 and 56.0 runs show 334 and
378 ms for `time to absent` because it was measured before the scanner fix —
that number is the cost of the scan, not of the deletion; the `erase_many`
duration is valid in every run).

This row matters: on a small file VACUUM is nearly free; at 5.2 MB deletion
takes 45–59 ms. Two orders of magnitude under the threshold (5,000 ms).

**Finding — the measured mechanism is not the designed mechanism.**
`docs/spec.md` §Deletion says VACUUM **left** the deletion path and runs only in
nightly maintenance (the reason: rewriting the whole file on every delete
breaks the p95 < 2 s threshold). In the code, `Vanish.erase_many/1` still calls
`purge/0`: checkpoint → `VACUUM` → checkpoint, inside the delete request. The
numbers above were measured **with VACUUM included** — that is, a heavier path
than the design asks for, and still 59 ms at 5.2 MB. The design's own path
(`secure_delete` + checkpoint, no VACUUM) was not measured separately, and the
`auto_vacuum=INCREMENTAL` pragma is not set in `Zifiri.Repo` either — the second
leg of §Deletion is not in the code.

Limit of the measurement: a file on the order of 1 GB was **not measured**.
VACUUM's cost grows with page count; a job that takes 53 ms at 5.2 MB cannot be
claimed to stay the same at 1 GB. Until this row is measured, "5 s at every
size" must not be written in the README.

## 7–9. PoW: how long 20 bits takes

```
node scripts/measure/pow_browser.js --bits 20 --trials 5
```

The message the server verifies is built exactly: `challenge_id` (16 bytes) ‖
`payload_hash` (32 bytes) ‖ nonce (u64be), SHA-256, 20 leading zero bits. The
hash is `@noble/hashes`, the version the browser client uses. The clock is
`process.hrtime.bigint()` — wall clock.

Three scenarios solve the same five challenges (attempt count identical:
**1,572,449** on average), the only difference being CPU speed: a slow CPU
computes the same hash 4/8 times. So there is no sleep and no multiplier applied
to the result — the measured time is real.

| scenario | attempts (avg) | min | median | max | Mhash/s |
|---|---|---|---|---|---|
| desktop (1×) | 1,572,449 | 431.7 ms | **1,838.8 ms** | 4,338.4 ms | 0.78 |
| phone assumption 4× | 1,572,449 | 1,682.3 ms | **7,563.9 ms** | 15,875.3 ms | 0.81 |
| phone assumption 8× | 1,572,449 | 3,259.9 ms | **13,338.5 ms** | 30,586.1 ms | 0.84 |

The `lib/zifiri/pow.ex` module doc says "20 bits is roughly a quarter of a
second in a browser worker". The measurement **does not support that**: median
1.84 s on a desktop, 0.43 s on the best run. The claim is ~7× optimistic. This
is a measurement result; the fix is a separate decision: either the difficulty
drops or the claim changes — neither is this file's job, but "a quarter of a
second" cannot be written in the README.

The distribution is wide (PoW is geometric): median 1.84 s, min 0.43 s, max
4.34 s. Writing a single run would be misleading; hence five independent
challenges and min/median/max.

Limit of the measurement: this is a Node process, not a real phone. The 4×/8×
scenarios slow the CPU but do not model a mobile browser's JIT difference,
thermal throttling, background restrictions or real device memory pressure. On
a real device the measurement is **not measured**.

## 10. Identity line

```
node -e "...base32(40 bytes)..."   → base32 64 characters
MIX_ENV=test mix run --no-start scripts/measure/identity_line.exs --samples 3
```

The prefix is `"zifiri1"` (7 characters), the body is the unpadded base32 of 40
bytes (64 characters). Total **71 characters** — the line the code produces:

```
zifiri1ISLO6YWRUEWPFN2Q2FJ6MVZYUBPAZBJRTSJAPF22VA6SRYTA5YOACAAAA6ME5JZE
  length           71
  prefix           "zifiri1" (7 chars)
  base32 part      64 chars
```

Independent check with `node -e`: 40 bytes → 64 base32 characters; `"zifiri1"`
+ 64 = **71**, `"zifir1"` + 64 = 70.

**Finding:** an earlier identity note said "70 characters, a
6-character `zifir1` prefix" and is stale. The code uses the `zifiri1` (7)
prefix and produces 71; `zifir1` is accepted only for decoding older lines.
`docs/spec.md` §Identity line says 71 — the measurement confirms it. The README
must say 71.

## Not measured

| what | why |
|---|---|
| Deletion in a database on the order of 1 GB | VACUUM's cost grows with file size; only 45 KB and 5.2 MB were measured |
| PoW on a real phone | 4×/8× CPU simulation; no device JIT, thermal or background restrictions |
| Server-side verification cost of a 20-bit PoW | `publish_latency` was pinned at 8 bits; 20-bit verification was not measured separately |
| Deletion under concurrent reads (the `{:error, :busy}` path) | The measurement runs alone; VACUUM returning busy while readers exist is a separate measurement |
| Length of the 4-group display | `docs/spec.md` says 85; the script's own 4-group layout gives 88 (71 + 17 spaces). The code has no display formatter, so this could not be verified |

## Reproducing

```
MIX_ENV=test mix run --no-start scripts/measure/publish_latency.exs
MIX_ENV=test mix run --no-start scripts/measure/erase_latency.exs
MIX_ENV=test mix run --no-start scripts/measure/erase_latency.exs --filler 5000 --trace
MIX_ENV=test mix run --no-start scripts/measure/identity_line.exs
node scripts/measure/pow_browser.js --bits 20 --trials 5
```

Every script writes JSON under `scripts/measure/results/` (run time, hardware,
raw numbers, threshold, result). A script that misses its threshold exits with
code 1, so it can be used in CI.
