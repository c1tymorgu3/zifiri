# Load measurements

Two scripts, one question each: how long does a write take before it is
readable, and how long does a feed page take under concurrency. Both run the
real application in `MIX_ENV=test`, against a throwaway database, and both write
their result as JSON next to this file.

```
scripts/load/
  load_support.exs    shared boot, HTTP client, statistics, report writer
  publish_load.exs    N concurrent POST /api/listings
  feed_load.exs       M concurrent GET /api/listings
  results/            one JSON per run, named <kind>-<UTC timestamp>.json
  baseline.md         the last real run on this machine, with numbers
```

## Running

From the repository root:

```sh
MIX_ENV=test mix run --no-start scripts/load/publish_load.exs
MIX_ENV=test mix run --no-start scripts/load/feed_load.exs
```

`--no-start` matters: the script sets the Repo and Endpoint config *before* the
application starts, so it can point them at
`_build/test/zifiri_load.db` and `127.0.0.1:4010`. Nothing touches
`zifiri_dev.db`, and the load database is deleted at the end of every run
(`LoadSupport.cleanup/1`), including the `-wal` and `-shm` files.

Knobs are environment variables, so `mix run` argument handling never matters:

| variable | default | meaning |
| --- | --- | --- |
| `LOAD_WRITES` | 500 | concurrent writes in the publish run |
| `LOAD_CONCURRENCY` | 500 | `Task.async_stream` concurrency for writes |
| `LOAD_PORT` | 4010 | local port the endpoint listens on |
| `LOAD_BITS` | 8 | PoW difficulty pinned for the run |
| `LOAD_TICK_MS` | 200 | unused by the current API (kept for the queue path) |
| `LOAD_ROWS` | 2000 | listings seeded before the feed run |
| `LOAD_FEED_CONCURRENCY` | 200 | simultaneous feed readers |

A smaller smoke run:

```sh
MIX_ENV=test LOAD_WRITES=20 LOAD_CONCURRENCY=20 mix run --no-start scripts/load/publish_load.exs
```

## What is measured

**publish_load.exs** — every write is a real one: a padded envelope from
`Zifiri.Envelope`, a challenge from the real `Zifiri.Pow.Challenge` store bound
to that owner and those exact bytes, a nonce solved by `Zifiri.Pow`, and a real
`POST /api/listings` through the endpoint, router, validation, proof redemption
and insert. Nothing is stubbed.

| field | definition |
| --- | --- |
| `write_ms` | POST start → `201 created`, one fresh TCP connection per request |
| `visible_ms` | one in ten writes is followed immediately by `GET /api/listings/:ref`; the number is that read-back's latency |
| `created` / `refused` | `201` count, and every other status grouped |
| `rows` | `SELECT count(*) FROM listings` after the run |
| `response_bytes` | must be exactly one value: every JSON reply is padded to 16 384 bytes |
| `memory` | `:erlang.memory(:total)` before, after writes, and at the end |

The challenge is issued **in-process at `LOAD_BITS` (8)**, not over
`POST /api/pow`. That endpoint issues at the production difficulty
(`Pow.difficulty/1`: 20 bits plus queue pressure), which turns 500 writes into
~500 million hashes and hours of wall clock; challenge issuance is not part of
the write latency, and the server side of the proof (`Challenge.redeem/5`) runs
in full either way. `test/support/forum_helpers.ex` pins four bits for the same
reason.

**feed_load.exs** — seeds `LOAD_ROWS` listings directly into the table (real
`Envelope.encode/1` bytes, so page sizes are realistic) and then runs two
phases:

| phase | definition |
| --- | --- |
| `cold` | `LOAD_FEED_CONCURRENCY` simultaneous reads, one fresh TCP connection each — includes connect + accept |
| `keepalive` | the same number of simultaneous connections, five requests each |
| `keepalive_steady` | requests 2..5 of each connection — pure server time |
| `bytes.uniform` | true only when every response body is the same size |
| `padding.all_padded` | every body ends in whitespace, i.e. was padded |
| `items_per_page` | listings that fit in one padded page |

## Targets (plan §16)

| measurement | target | source |
| --- | --- | --- |
| write latency p95 (`write_ms`) | < 2 000 ms | §16 |
| feed response p95 (`response_ms`) | < 300 ms | §16 |
| every JSON reply | 16 384 bytes | §4.1 |

`baseline.md` records the last real run against these targets, including the
ones that were missed and why. The short version of that run: writes pass
(p95 162 ms), the feed does not (p95 1 114 ms at 200 readers, and one request in
two is a `500`) because every feed request scans and sorts the whole `listings`
table — see the `EXPLAIN QUERY PLAN` in `baseline.md`.

## Server-side assumptions the numbers depend on

* **`pool_size: 8`.** `LoadSupport.boot/1` removes the test sandbox pool and sets
  eight connections. A smaller pool fails sooner under the same read load; a
  bigger one fails later. The number is in every JSON under `config`.
* **`limit=30`.** The feed page is capped by the router's 16 384-byte budget, not
  by the limit: with the seeded size mix a page holds ten listings.
* **2 000 seeded rows.** The feed query has no index that serves its order, so
  read latency grows with the table; 2 000 rows is the size all feed numbers here
  were taken at.

## Caveats worth knowing before quoting a number

* **One machine, one process, one file.** The server, the client and SQLite all
  live on the same box; the client competes with the server for CPU. These are
  ceiling numbers, not production numbers.
* **Windows + Defender.** The first write transaction after a fresh file can pay
  a multi-hundred-millisecond fsync. `publish_load.exs` runs a ten-write warm-up
  and deletes it before measuring, so the first measured write is not also the
  first write this VM ever made — but the disk is still the disk.
* **A fresh TCP connection per request** in the cold phases. That is deliberate
  (a client that has just opened the app pays it) and it is why the keep-alive
  phases exist as the other half of the answer.
* **`LOAD_BITS=8` is not the production difficulty.** Latency here excludes the
  client's real proof-of-work cost; on a phone at 20 bits that cost dominates
  everything this script measures.
