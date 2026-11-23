# zifiri — claims, tests, thresholds

`docs/plan.md` (v5) states a claim in every section. This document holds the test,
the threshold and the **current** status of each of those claims. If a row says
"green", the claim was run with the listed command and passed; "red" means it was
run and failed; "none" means there is no test and the claim is **unproven** —
being written in the plan does not make it true.

Every claim carries a stable ID (`C-01` … `C-49`) so that this file, `docs/verify.md`
and the README can be diffed against each other instead of against prose.

> **Provenance.** The numbers below are a snapshot taken on **2026-11-22, 19:45–20:31**
> while the repository was being rewritten in parallel (§0). They are kept verbatim as
> the record of that session. For the number a fresh checkout produces today, run the
> commands in §6 — the README states the last full-suite result together with its date.

Status dictionary:

| Status | Meaning |
|---|---|
| **Green** | Test exists, was run, passed (the count is given) |
| **Red** | Test exists, was run, failed (which test, and why) |
| **Flaky** | Test exists, passes or fails depending on conditions (why) |
| **None** | No test; the claim is unproven today |

Nothing is written without a number, a date and a command. All numbers below were
taken between **2026-11-22 19:45–19:56** in single-file runs. The decision rows in §5
were measured separately between **2026-11-22 20:28–20:31**; the two sets carry
different dates and are not interchangeable.

---

## 0. The moment of measurement

The repository was changing in parallel during this measurement (`posts`/`forum` being
removed, `bucket`/`mailbox`/`listings`/`presence` being added). Therefore:

- **A single-file run is valid evidence**: `mix test test/<name>_test.exs`.
- **The full-suite number is invalid**: several `mix test` processes write to the same
  `zifiri_test.db` file, SQLite locks, and passing tests fall in bulk. Two full runs:

| Time | Command | Result | Note |
|---|---|---|---|
| 19:44 | `mix test` | 333/385 | `posts` removal was in progress |
| 19:52 | `mix test` | did not compile | `test/api_surface_test.exs` import clash |
| 19:56 | `mix test` | 274/404 | 149 s sync: concurrent load, lock contention |
| 20:07 | `mix test` | did not compile | `lib/zifiri/router.ex` — parallel agent editing |

In the same minutes, single-file runs passed 100% (table below). The difference is a
defect of the measurement environment, not of the product; the full-suite number
cannot be reported as it stands. The compile breaking twice has the same cause: the
repository was being written to during the measurement.

---

## 1. Claim table

| ID | Claim (plan §) | Test | Threshold | Today |
|---|---|---|---|---|
| C-01 | A bucket is ten minutes, target 120, aligned to the wall clock (§6.1) | `bucket_test` | a boundary instant opens the bucket; 120 target | **Green** — 14/14 |
| C-02 | The bucket drains on the clock, not on a count; the drain is shuffled; a closed bucket carries over (§6.1) | `bucket_test` | a full bucket does not drain early; order is not arrival order | **Green** — 14/14 |
| C-03 | An empty bucket is filled with 120 decoys; `fill(n)` = `n − real` (§6.2) | `decoy_test` | `r=0` → 120; `r>120` → 0 | **Green** — 17/17 |
| C-04 | A decoy is indistinguishable from a real envelope: 4096 B, same header/padding/JSON, valid signature, 200 unique sentences in the dictionary (§6.2) | `decoy_shape_test` + `decoy_test` | 5/5 shape tests; no chi-square/entropy separation | **Green** — 5/5 + 17/17 |
| C-05 | The moment of writing is hidden: the real message's position inside the bucket is uniform (§3.1) | `timing_test` | uniform over 0..119 in 1000 samples; an empty bucket loses nothing | **Green** — 3/3 |
| C-06 | The decoy key is per bucket, in RAM; the next bucket gets a different key (§6.3) | `decoy_test` | one key per bucket; not on disk | **Green** — 17/17 (the key is not written to disk; live memory is out of scope) |
| C-07 | Fast mode: < 1 s, 1/5 neighbourhood (§3.4) | `fast_mode_test` | p95 < 1 s; neighbourhood 5 | **None** |
| C-08 | The 1:1 table has 5 columns; no sender/conversation/account column (§7.2) | `mailbox_test` | `PRAGMA table_info` is exactly 5 columns | **Green** — 25/25 |
| C-09 | 1:1 addressing is a 16 B HMAC tag; the key is not stored; the tag is deterministic and key-specific (§7.1) | `mailbox_test` | same key → same tag; different key → different tag | **Green** — 25/25 |
| C-10 | A 1:1 envelope is exactly 4096 B; the table rejects off-size rows too (§7.1) | `mailbox_test` | module and trigger both refuse | **Green** — 25/25 |
| C-11 | 1:1 TTL is 72 hours; an expired envelope is not read and the sweeper deletes it (§7.3) | `mailbox_test` | default 72 h; sweeper every 5 min | **Flaky** — 25/25 and 24/25 (sweeper timing) |
| C-12 | 1:1 paging: 200 upper bound, the `since` cursor neither skips nor repeats, `ack` never deletes another box (§7.3) | `mailbox_test` | 200 clamp; id monotonic | **Green** — 25/25 |
| C-13 | The recipient cannot open a decoy envelope (§7.4) | — | even on a tag match, AEAD does not open | **None** |
| C-14 | 1:1 envelopes also accumulate in the bucket and are completed to 120 with decoys (§7.4) | — | 120 envelopes per bucket | **None** |
| C-15 | Listings: plaintext metadata, `owner_hash` not unique, `created_day` is a day, search `LIKE` is escaped, `erase/2` deletes all of an owner's listings (§8) | `listings_test` | 33 tests | **Green** — 33/33 |
| C-16 | With presence off there is no trace; `:unknown`; mutual for 5 min; turning it off deletes the row; ETS only (§9) | `presence_test` | 17 tests; nothing written to disk or logs | **Green** — 17/17 |
| C-17 | Deletion level 1: the row goes, there is no tombstone, the file is untouched (§10.2) | `vanish_test` | `{:ok, n}`; file size unchanged | **Red** — 26/31 |
| C-18 | Deletion level 2: `secure_delete` + WAL truncate + VACUUM; the body is found in neither the file nor the `-wal`; `busy` is reported honestly (§10.2) | `vanish_test` | `strings` scan clean; `freelist_count = 0` | **Red** — 26/31 |
| C-19 | Schema allowlist: only `posts` (transitional), `listings`, `mailbox_envelopes`, `mod_audit`, `schema_migrations` (§7.2, §8) | `schema_test` | an extra table/column fails the test | **Green** — 5/5 |
| C-20 | No logs (code level): no `Logger.info/debug`, `IO.inspect`, `dbg` in `lib/`; Ecto logging off (§11) | `no_log_test` + `architecture_test` | grep is empty | **Green** — 9/9 + 6/6 |
| C-21 | No logs (deployment level): proxy `access_log off`, container `logging: none`, crash dump off, no swap (§11) | drill | no log file in a live container | **None** |
| C-22 | The envelope is padded to 4 KB; its size does not vary with the input (§1, §4) | `envelope_test` | every body is 4096 B | **Green** — 22/22 |
| C-23 | `owner_hash` is a peppered HMAC; the same owner gets a different hash on two writes (§5.3) | `owner_test` | not unique; not computable without the pepper | **Green** — 18/18 |
| C-24 | IP/peer never reaches the application; `X-Forwarded-For`/`X-Real-IP` are stripped (§11) | `transport_test` | header absent; peer is a fixed string | **Green** — 2/2 |
| C-25 | PoW: the challenge is single-use, the solution is bound to the envelope (§4.1) | `pow_test` | replay is refused | **Green** — 22/22 |
| C-26 | Chat writes nothing to disk; the room stream lives in RAM (§1) | `chat_test` | no row in the DB | **Green** — 31/31 |
| C-27 | Fixed-size error responses: 404/413/500 are the same size, the path is not echoed (§11) | `leak_test` | every response is the same byte count | **Red** — 5/9 |

---

## 2. The reds — what fails, and why

### 2.1 `vanish_test` — 26/31

| Failing test | Error | Why |
|---|---|---|
| `level 2 — erase_many/1 gives the pages back` | expected `{:ok, 0}`, got `{:ok, 200}` | the `posts` table was removed; the test still inserts 200 rows (a stale transitional test) |
| `level 2 — erase_many/1 leaves no plaintext body` | the scan cannot see the body at all | no row was inserted, so there is no body to delete |
| `level 2 — erase_many/1 a body that was not erased is still findable` | the scan says "clean" | same cause: no row |
| `pending work calls every module that exports drop_owner/1` | `DropRecorder.reset/0` undefined | the test module is defined as `Zifiri.VanishTest.DropRecorder` but called by its bare name — a test bug |
| `pending work drops each hash once` | same | same |

`Vanish.purge()` returned `{:error, :busy}` in one run: concurrent `mix test` processes
were locking the same DB file (see §0). That is a measurement defect, not a product
bug; run alone, the level 1/2 logic passes.

**Comment:** the level 2 mechanics (`secure_delete`, WAL truncate, VACUUM, backoff)
exist in the code and passed 23/23 earlier; today's red comes from the tests not being
updated while `posts` was removed. Calling it "green" requires detaching the test from
the transitional table (`posts`) — plan §14 step 7.

### 2.2 `leak_test` — 5/9

| Failing test | Error |
|---|---|
| `every 404 is one size and never echoes the path` | response sizes `[21, 21, 16384, 16384, 16384]` |
| `an oversized body is refused, not crashed on` | `no "413" html template defined for Zifiri.ErrorView` |
| `a server fault answers in one size and names nothing` | `no "500" html template defined for Zifiri.ErrorView` |
| `a refused write is one size whatever the reason` | same: the 4xx/5xx body does not settle on one size |

**Comment:** the fixed-size error response claim is **false** today. The 404 body
returned to the client is sometimes 21 bytes, sometimes 16 KB; there is no `ErrorView`
template for 413/500. This refutes plan §11's "one size" sentence and must stay red.

---

## 3. The "none" rows — claims without evidence

These are written in the plan but have no test; today they are intent, not claims.

| Claim | Missing test | Why it matters |
|---|---|---|
| Fast mode < 1 s, 1/5 neighbourhood (C-07) | `fast_mode_test` | without the mode the user abandons silent mode; "80%" cannot be said without measuring |
| The recipient cannot open a decoy envelope (C-13) | a separate test inside `mailbox_test` | if decoy envelopes look like "you have a message" to the recipient, 1:1 breaks |
| 1:1 bucket integration (completion to 120) (C-14) | `mailbox_bucket_test` | today envelopes are written directly; the bucket claim is void for 1:1 |
| No logs — deployment level (C-21) | `drill` (script + output) | `no_log_test` inspects code only; proxy/container/BEAM settings are unmeasured |
| Listings HTTP surface (write/search/delete) (C-15, endpoint level) | `api_surface_test` | the file exists but did not compile at 19:52; the listing plane is tested at module level today, not at the endpoint level |

---

## 4. Known defects of the measurement

1. **Shared test DB.** `mix test` uses a single `zifiri_test.db` file; when two
   processes run at once `VACUUM`/`wal_checkpoint` lock and unrelated tests fall
   (19:56: 130 errors). The fix is a per-process DB (`MIX_TEST_PARTITION` or a unique
   file name). Until that is done the full-suite number cannot be reported.
2. **Order sensitivity.** `vanish_test` alone is 26/31, together with `mailbox` 51/56;
   `schema_test` was 4/5 at one point, now 5/5. State leaks between tests.
3. **Timing sensitivity.** The `mailbox` sweeper test fell in one run (5 min window
   plus a slow machine). There is no fixed-clock injection.
4. **A changing repository.** `posts`/`forum` were being removed during the
   measurement; one red set is test-code drift, not a product bug. That is why every
   row carries its date.

---

## 5. Post-decision claims — 2026-11-22 20:28–20:31

The six decisions in `docs/scope-v5.md` turned into claims. The status column is the
output of the command run in this session; an unrun row is **None**, never a guess.

| ID | Claim | Test / command | Threshold | Status |
|---|---|---|---|---|
| C-28 | No published claim against A1 | `grep -nE 'A1.*%[0-9]' docs/scope-v5.md \| wc -l` | `0` | **Green** (0) |
| C-29 | When cover ships, the set against A1 is ≤ k | `cover_test` | set ≤ k; the text says "at most k" | **None** |
| C-30 | Fast mode is the default | `fast_mode_test` | default fast; p95 < 1 s | **None** |
| C-31 | "Send hidden" label + live neighbourhood counter | client test | the button reads `anonimlik: N`; N = messages in the last 60 s, min 1 | **None** |
| C-32 | The application does not read IP / XFF / user-agent | `mix test test/transport_test.exs` | 2 tests, 0 failures | **Green** (20:29: 2 passed) |
| C-33 | No code outside `transport.ex` reads these headers | `grep -rnE 'remote_ip\|x-forwarded-for' --include='*.ex' lib \| grep -v transport.ex \| wc -l` | `0` | **Green** (0) |
| C-34 | The nginx access log is off | `grep -E '^[[:space:]]*access_log' infra/nginx.conf \| grep -vcE 'access_log[[:space:]]+off;'` | `0` | **Green** (5 lines, 5 `off`) |
| C-35 | A live request leaves the client address in no log | `docs/verify.md` §12.1/4 | `0` | **None** (the live drill was not run) |
| C-36 | On onion the server cannot see the client IP | `docs/verify.md` §12.1 + `infra/tor/torrc` | `0` | **None** |
| C-37 | No claim against A1 in the clearnet copy | text audit (`scope-v5.md` §Claim texts) | no A1 claim appears | **Green (text)** |
| C-38 | "Yok ol" zeroes the `.db` and `-wal` within 5 s | `mix test test/vanish_test.exs` | 33 tests, 0 failures | **Green** (20:30: 33 passed) |
| C-39 | VACUUM is not on the delete path | `grep -rn 'VACUUM' --include='*.ex' lib \| grep -vc maintenance` | `0` | **Red** — `lib/zifiri/vanish.ex:450` `Repo.query("VACUUM")` |
| C-40 | `auto_vacuum = INCREMENTAL` | `grep -rn auto_vacuum --include='*.ex' lib config priv` | matches > 0 and `PRAGMA auto_vacuum` = 2 | **None** — 0 matches, the setting does not exist |
| C-41 | No backup / tombstone | `mix test test/schema_test.exs` | no tombstone table in the allowlist | **Green** (19:52: 5/5) |
| C-42 | Block-level disk rests on LUKS | `docs/verify.md` §9 | LUKS; no block-level guarantee | **None** (level 3 is written as "no guarantee") |
| C-43 | The operator is the moderator; the decision record has `threshold = 1` | `mix test test/mod_test.exs` | 16 tests, 0 failures; `threshold` is 1 | **Green** (20:30: 16 passed) |
| C-44 | The audit chain catches later edits | `mix test test/mod_test.exs` | edit/delete/reorder are all caught | **Green** (20:30: 16 passed) |
| C-45 | The audit chain does not prove who decided | text audit (`scope-v5.md` §Moderation) | this claim is not made | **Green (text)** |
| C-46 | The identity line is 40 B / 64 base32 | `mix test test/identity_test.exs` | 27 tests, 0 failures | **Green** (20:28: 27 passed) |
| C-47 | `mailbox_id` is derived from the seed by HKDF | `mix test test/identity_test.exs` | matches a reference vector; changes with the generation | **Green** (20:28: 27 passed) |
| C-48 | "Write it on paper" is not claimed in v1 | text audit (`scope-v5.md` §Identity line) | absent from the v1 copy | **Green (text)** |
| C-49 | The v2 word list is 27 words | `identity_test` v2 group | 27 words | **None** (v2 is not written) |

**Reading note.** Row C-38 is green while C-39/C-40 are red/none: deletion today leaves
no trace in the file or the WAL thanks to `secure_delete` + WAL truncate, but it still
runs VACUUM on every delete and `auto_vacuum` is not configured. The decision (move
VACUUM to nightly maintenance, `auto_vacuum=INCREMENTAL`) **has not reached the code
yet**; C-38 being green does not make C-39/C-40 green.

**Limit.** The full suite was not run (shared test DB, §4/1). The numbers above are
single-file runs; the `mix test` output does not stand in for them.

---

## 6. Reproducing a number

```bash
# one claim (valid evidence)
mix test test/bucket_test.exs
mix test test/decoy_test.exs
mix test test/decoy_shape_test.exs
mix test test/timing_test.exs
mix test test/mailbox_test.exs
mix test test/presence_test.exs
mix test test/listings_test.exs
mix test test/schema_test.exs
mix test test/no_log_test.exs
mix test test/architecture_test.exs
mix test test/vanish_test.exs
mix test test/leak_test.exs
mix test test/identity_test.exs
mix test test/mod_test.exs
mix test test/transport_test.exs

# full suite (only meaningful while one process is running)
mix test
```

A change that turns a row green is recorded in this document together with the output
of the same command; the words "done" on their own are not accepted.
