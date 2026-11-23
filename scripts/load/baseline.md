# Baseline — measured on this machine

Everything below is a real run, not an estimate. Each row names the JSON file it
came from in `results/`; those files are the raw output.

| | |
| --- | --- |
| measured | 2026-11-22, 20:18–20:24 local (UTC+03) |
| machine | Windows 11, 8 logical cores |
| runtime | Elixir 1.20.5, Erlang/OTP 29.1.2, Phoenix 1.8.17, Bandit 1.15.0, exqlite |
| environment | `MIX_ENV=test`, throwaway DB `_build/test/zifiri_load.db`, deleted after each run |
| write path measured | `POST /api/listings` |
| read path measured | `GET /api/listings?limit=30` |
| PoW | pinned to 8 bits (`LOAD_BITS=8`) |
| DB pool | `pool_size: 8` (set by `LoadSupport.boot/1`, no Ecto sandbox) |

**The tree was moving while this was measured.** The repository has no commits;
other work was landing in `lib/` during the window (the endpoint, the router and
the application supervision tree all changed, and the old queue-based publish
path — `POST /api/posts`, `Zifiri.Publish.Queue` / `Turn` / `Worker` — was
removed outright). The numbers describe the API that existed at 20:18–20:24:
listings written inline, no publication turn. Anything measured earlier in the
same session against `/api/posts` was thrown away, because that endpoint no
longer exists.

## Write path — 500 concurrent writes

`results/publish-20261122T171855641000.json`

| | value |
| --- | --- |
| writes attempted | 500, all concurrent (`Task.async_stream`, 500) |
| accepted (`201`) | **500** |
| refused | **0** |
| transport errors | 0 |
| rows in `listings` afterwards | 500 |
| wall clock | 459 ms |
| throughput | 1 089 writes/s |
| response size | 16 384 bytes for all 500 replies (uniform) |
| memory (`:erlang.memory(:total)`) | 59.3 MiB before, 62.1 MiB after writes, 62.1 MiB at end |

Latency, milliseconds:

| measurement | min | p50 | **p95** | p99 | max | mean |
| --- | --- | --- | --- | --- | --- | --- |
| write (POST start → `201`) | 7.1 | 130.0 | **162.3** | 177.4 | 211.8 | 113.5 |
| visible (POST done → `GET /api/listings/:ref` = 200), n=50 | 3.4 | 83.4 | **141.8** | 159.0 | 159.0 | 81.4 |

All 50 sampled writes were readable; none timed out.

**Against the target (publish p95 < 2 000 ms): passes, 12× under.** The number
is dominated by CPU contention among 500 client processes on 8 cores plus SQLite
writes on one file, not by the server's own work: at 20 concurrent writes the
same path measures p50 12.4 ms / p95 17.3 ms.

## Read path — feed

Two runs, same 2 000 seeded listings (1 400 × 256 B, 400 × 1 KB, 200 × 4 KB
envelopes), five requests per connection in the keep-alive phase.

### 50 simultaneous readers

`results/feed-20261122T172338076000.json` — 300/300 requests answered `200`, no
errors.

| phase | min | p50 | **p95** | p99 | max | mean |
| --- | --- | --- | --- | --- | --- | --- |
| cold (new connection per request) | 29.7 | 176.2 | **297.9** | 301.0 | 301.0 | 174.3 |
| keep-alive | 48.3 | 303.4 | **322.2** | 331.8 | 340.3 | 281.0 |
| keep-alive, requests 2–5 | 280.9 | 306.1 | **322.2** | 331.8 | 340.3 | 306.4 |

Throughput 164 req/s cold, 162 req/s keep-alive. Every body was exactly 16 384
bytes, padded, and held 10 listings.

### 200 simultaneous readers

`results/feed-20261122T172346137000.json`

| phase | requests | `200` | `500` | throughput |
| --- | --- | --- | --- | --- |
| cold | 200 | 200 | 0 | 159 req/s |
| keep-alive | 1 000 | 507 | **493** | 148 req/s |

| phase | min | p50 | **p95** | p99 | max | mean |
| --- | --- | --- | --- | --- | --- | --- |
| cold | 49.4 | 614.1 | **1 113.6** | 1 149.9 | 1 157.5 | 589.5 |
| keep-alive (`200` responses only) | 37.6 | 1 310.5 | **1 364.8** | 1 375.9 | 1 412.7 | 964.5 |
| keep-alive steady (`200` only) | 101.8 | 1 336.4 | **1 372.3** | 1 383.5 | 1 412.7 | 1 155.1 |

The latency columns above are the **successful** requests; the 493 failures are
not in them and were slower still — they are the `500`s, and the previous run of
the same shape also produced 265 dropped connections. Those `500`s come from the
server raising inside the request and Phoenix then failing to render an error
page (`no "500" html template defined for Zifiri.ErrorView`), so the client sees
a connection that dies mid-exchange.

**Against the target (feed p95 < 300 ms): fails.** At 50 simultaneous readers it
is already borderline (297.9 ms cold, 322.2 ms keep-alive); at 200 it is 4× over
and one request in two is a `500`.

### Why — evidence, not a guess

```
EXPLAIN QUERY PLAN SELECT id, title, body FROM listings
  WHERE status = 'open' ORDER BY created_day DESC, id DESC LIMIT 30;

SCAN listings
USE TEMP B-TREE FOR ORDER BY
```

Every feed request scans the whole table and sorts it in a temp b-tree; the
existing indexes are `(category, created_day)` and `(owner_hash)`, and neither
serves `status = 'open' ORDER BY created_day DESC, id DESC`. Measured cost of
that one query: **3.3 ms at 2 000 rows**, and it grows with the table. With a
pool of 8 connections that caps the service at roughly 8 / 0.0033 ≈ 2 400
queries/s in theory, and far less in practice because the scan competes for CPU
with the JSON encode and base64 of ten envelopes (up to 5.4 KB each).

At 200 simultaneous readers the checkout queue exceeds Ecto's
`queue_target`/`queue_interval` budget, `DBConnection` raises, and the request
becomes a `500` — which is exactly the failure pattern above: fast `200`s
interleaved with `500`s, and a p95 that sits at the 1.3–1.4 s mark.

Two things would move this number, in order of effect:

1. an index that serves the feed order (`status`, `created_day DESC`, `id DESC`);
2. a larger pool and/or fewer, smaller envelopes per page.

Neither is a load-script change, so neither was applied — this file records what
the tree does today.

## The padding claim — verified

Every response body in every phase of every run above was exactly **16 384
bytes** and ended in padding whitespace, including the `201` replies and the
`500`s. That is `Zifiri.Router.reply/3` doing what §4.1 says it does. Two
consequences worth writing down:

* a page holds **10 listings** with the seeded size mix (1 400 small, 400
  medium, 200 large) — the budget stops at ten because three of the newest
  thirty are 4 KB envelopes (5 464 bytes of base64 each);
* because every response is the same size, **response size carries no signal** —
  but response *time* does: a `500` and a `200` are both 16 384 bytes, and the
  failing requests are the slowest ones. The padding hides content, not
  liveness.

## Not measured, and why

| thing | status | reason |
| --- | --- | --- |
| queue entry / publication turn (`tur yayın süresi`) | **not measured** | the write path in this tree has no queue: `POST /api/listings` validates, redeems the proof and inserts inline, then answers `201`. `Zifiri.Publish.Queue` / `Turn` / `Worker` were removed from `lib/` during the measurement window, so there is no turn to time. |
| production PoW cost (20 bits) | **not measured** | at 20 bits each write is ~1 M hashes; 500 of them is hours of wall clock. The scripts pin 8 bits and say so; the client-side cost at production difficulty is not in any number here. |
| sustained load (minutes, not seconds) | **not measured** | every run is a burst: 500 writes in 0.5 s, 1 000 reads in 3.4 s. Nothing here says what happens after ten minutes, when the table is larger and the page cache is warm. |
| concurrency between writes and reads | **not measured** | the two scripts run one after the other; a mixed workload was not attempted. |
| multi-machine / real network | **not measured** | client and server share one box and one loopback interface. |

## Reproducing

```sh
MIX_ENV=test mix run --no-start scripts/load/publish_load.exs   # 500 writes
MIX_ENV=test mix run --no-start scripts/load/feed_load.exs      # 200 readers, 2 000 rows
MIX_ENV=test LOAD_FEED_CONCURRENCY=50 mix run --no-start scripts/load/feed_load.exs
```

The database is created fresh per run and deleted afterwards; nothing under
`_build/test` survives a run except the JSON in `results/`.
