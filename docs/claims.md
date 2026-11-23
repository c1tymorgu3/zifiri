# zifiri — claims, tests, thresholds

The anonymity claim is the product. Everything else in this repository exists to make
that claim checkable: a test, a command, a number, a date. What an instance publishes
is its operator's decision; this repository is about who can be identified, and about
whether that answer survives contact with the code.

A1 — the operator — is outside the model. The design assumes the operator complies and
minimises what compliance yields: no account, no sender column, **1/120** positions
inside a ten-minute bucket, a **4096 B** envelope that never varies, a **71-character**
identity line that carries no public key. A row below is either inside that model or
explicitly outside it; the rows outside it are named, not softened.

Every claim below comes from the contract in `docs/spec.md`; the `§` numbers in the
tables are the plan's, and the plan text itself is not published. This
document holds the test, the threshold, why the claim is load-bearing, and the
**current** status of each one. If a
row says "green", the claim was run with the listed command and passed; "red" means it
was run and failed; "none" means there is no test and the claim is **unproven** — being
written in the plan does not make it true.

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
defect of the measurement environment: the full-suite number establishes nothing about
the product either way, and the two compile breaks have the same cause — the repository
was being written to during the measurement.

---

## 1. Claim table

| ID | Claim (plan §) | Why it matters | Test | Threshold | Today |
|---|---|---|---|---|---|
| C-01 | A bucket is ten minutes, target 120, aligned to the wall clock (§6.1) | The ten-minute bucket is the unit of anonymity: **1/120** is the whole claim. | `bucket_test` | a boundary instant opens the bucket; 120 target | **Green** — 14/14 |
| C-02 | The bucket drains on the clock, not on a count; the drain is shuffled; a closed bucket carries over (§6.1) | A drain on arrival order hands the observer the order of writes. | `bucket_test` | a full bucket does not drain early; order is not arrival order | **Green** — 14/14 |
| C-03 | An empty bucket is filled with 120 decoys; `fill(n)` = `n − real` (§6.2) | An empty bucket says "one message was sent"; a full one says only "**120** arrived". | `decoy_test` | `r=0` → 120; `r>120` → 0 | **Green** — 17/17 |
| C-04 | A decoy is indistinguishable from a real envelope: 4096 B, same header/padding/JSON, valid signature, 200 unique sentences in the dictionary (§6.2) | If a decoy can be told apart, the padding is decoration and **1/120** is a fiction. | `decoy_shape_test` + `decoy_test` | 5/5 shape tests; no chi-square/entropy separation | **Green** — 5/5 + 17/17 |
| C-05 | The moment of writing is hidden: the real message's position inside the bucket is uniform (§3.1) | The position inside the bucket is the only clock an observer has left. | `timing_test` | uniform over 0..119 in 1000 samples; an empty bucket loses nothing | **Green** — 3/3 |
| C-06 | The decoy key is per bucket, in RAM; the next bucket gets a different key (§6.3) | A key on disk lets a disk image separate real from decoy after the fact. | `decoy_test` | one key per bucket; not on disk | **Green** — 17/17 (the key is not written to disk; live memory is out of scope) |
| C-07 | Fast mode: < 1 s, 1/5 neighbourhood (§3.4) | Fast mode is the default, so its **1-in-5** neighbourhood is the number most users actually get. | `fast_mode_test` | p95 < 1 s; neighbourhood 5 | **None** |
| C-08 | The 1:1 table has 5 columns; no sender/conversation/account column (§7.2) | A sender column puts a name back on the row the whole design removes. | `mailbox_test` | `PRAGMA table_info` is exactly 5 columns | **Green** — 25/25 |
| C-09 | 1:1 addressing is a 16 B HMAC tag; the key is not stored; the tag is deterministic and key-specific (§7.1) | The tag addresses a mailbox without storing the key that produced it. | `mailbox_test` | same key → same tag; different key → different tag | **Green** — 25/25 |
| C-10 | A 1:1 envelope is exactly 4096 B; the table rejects off-size rows too (§7.1) | A **4096 B** envelope that never varies keeps length out of the observation. | `mailbox_test` | module and trigger both refuse | **Green** — 25/25 |
| C-11 | 1:1 TTL is 72 hours; an expired envelope is not read and the sweeper deletes it (§7.3) | Expiry bounds how long a mailbox can be watched before it is empty by construction. | `mailbox_test` | default 72 h; sweeper every 5 min | **Flaky** — 25/25 and 24/25 (sweeper timing) |
| C-12 | 1:1 paging: 200 upper bound, the `since` cursor neither skips nor repeats, `ack` never deletes another box (§7.3) | A cursor that skips or repeats lets a reader infer traffic that is not there. | `mailbox_test` | 200 clamp; id monotonic | **Green** — 25/25 |
| C-13 | The recipient cannot open a decoy envelope (§7.4) | A decoy the recipient can open is a message; the recipient must see noise, not content. | — | even on a tag match, AEAD does not open | **None** |
| C-14 | 1:1 envelopes also accumulate in the bucket and are completed to 120 with decoys (§7.4) | Without the bucket, 1:1 writes its own arrival clock and **1/120** does not apply to it. | — | 120 envelopes per bucket | **None** |
| C-15 | Listings: plaintext metadata, `owner_hash` not unique, `created_day` is a day, search `LIKE` is escaped, `erase/2` deletes all of an owner's listings (§8) | Listings are public by design; the claim is only that no account sits behind them. | `listings_test` | 33 tests | **Green** — 33/33 |
| C-16 | With presence off there is no trace; `:unknown`; mutual for 5 min; turning it off deletes the row; ETS only (§9) | Presence is the one place where "off" must mean no row, not a row saying off. | `presence_test` | 17 tests; nothing written to disk or logs | **Green** — 17/17 |
| C-17 | Deletion level 1: the row goes, there is no tombstone, the file is untouched (§10.2) | Level 1 is the API promise: the row leaves every read path. | `vanish_test` | `{:ok, n}`; file size unchanged | **Red** — 26/31 |
| C-18 | Deletion level 2: `secure_delete` + WAL truncate + VACUUM; the body is found in neither the file nor the `-wal`; `busy` is reported honestly (§10.2) | Level 2 is the disk promise: the body is in neither the file nor the `-wal`. | `vanish_test` | `strings` scan clean; `freelist_count = 0` | **Red** — 26/31 |
| C-19 | Schema allowlist: only `posts` (transitional), `listings`, `mailbox_envelopes`, `mod_audit`, `schema_migrations` (§7.2, §8) | An allowlist is how "no identity column" survives the next migration. | `schema_test` | an extra table/column fails the test | **Green** — 5/5 |
| C-20 | No logs (code level): no `Logger.info/debug`, `IO.inspect`, `dbg` in `lib/`; Ecto logging off (§11) | One `Logger.info` writes the body to a file the design says does not exist. | `no_log_test` + `architecture_test` | grep is empty | **Green** — 9/9 + 6/6 |
| C-21 | No logs (deployment level): proxy `access_log off`, container `logging: none`, crash dump off, no swap (§11) | Code can be clean while the proxy writes every request to disk. | drill | no log file in a live container | **None** |
| C-22 | The envelope is padded to 4 KB; its size does not vary with the input (§1, §4) | Size is the cheapest side channel; **4096 B** removes it. | `envelope_test` | every body is 4096 B | **Green** — 22/22 |
| C-23 | `owner_hash` is a peppered HMAC; the same owner gets a different hash on two writes (§5.3) | Without the pepper a hash is a lookup key; with it, it is a pseudonym. | `owner_test` | not unique; not computable without the pepper | **Green** — 18/18 |
| C-24 | IP/peer never reaches the application; `X-Forwarded-For`/`X-Real-IP` are stripped (§11) | If the application never sees the address, no code path can store it. | `transport_test` | header absent; peer is a fixed string | **Green** — 2/2 |
| C-25 | PoW: the challenge is single-use, the solution is bound to the envelope (§4.1) | A replayable challenge is a free write, and free writes are how a bucket is flooded. | `pow_test` | replay is refused | **Green** — 22/22 |
| C-26 | Chat writes nothing to disk; the room stream lives in RAM (§1) | Chat is the surface most likely to be logged; it writes nothing. | `chat_test` | no row in the DB | **Green** — 31/31 |
| C-27 | Fixed-size error responses: 404/413/500 are the same size, the path is not echoed (§11) | An error that echoes the path or changes size is a read oracle. | `leak_test` | every response is the same byte count | **Red** — 5/9 |

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
were locking the same DB file (see §0). The cause is the shared DB file; run alone, the
level 1/2 logic passes.

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
template for 413/500. This refutes plan §11's "one size" sentence and stays red until
the sizes settle.

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
   measurement; one red set comes from test code that still targets the removed table.
   That is why every row carries its date.

---

## 5. Post-decision claims — 2026-11-22 20:28–20:31

The six decisions in `docs/spec.md` turned into claims. The status column is the
output of the command run in this session; an unrun row is **None**, never a guess.

| ID | Claim | Why it matters | Test / command | Threshold | Status |
|---|---|---|---|---|---|
| C-28 | No published claim against A1 | A claim against the operator is unprovable; the model stops where the operator begins. | `grep -nE 'A1.*%[0-9]' docs/spec.md \| wc -l` | `0` | **Green** (0) |
| C-29 | When cover ships, the set against A1 is ≤ k | Cover narrows the set; the text may say "at most k" and nothing stronger. | `cover_test` | set ≤ k; the text says "at most k" | **None** |
| C-30 | Fast mode is the default | The default is the mode most users get, so it has to be the honest one. | `fast_mode_test` | default fast; p95 < 1 s | **None** |
| C-31 | "Send hidden" label + live neighbourhood counter | The button states the current neighbourhood instead of burying it in a footnote. | client test | the button reads `anonymity: N`; N = messages in the last 60 s, min 1 | **None** |
| C-32 | The application does not read IP / XFF / user-agent | Not reading the header is stronger than deleting it later. | `mix test test/transport_test.exs` | 2 tests, 0 failures | **Green** (20:29: 2 passed) |
| C-33 | No code outside `transport.ex` reads these headers | One exemption is a boundary; two are a hole. | `grep -rnE 'remote_ip\|x-forwarded-for' --include='*.ex' lib \| grep -v transport.ex \| wc -l` | `0` | **Green** (0) |
| C-34 | The nginx access log is off | A proxy log is a complete access record with an address on every line. | `grep -E '^[[:space:]]*access_log' infra/nginx.conf \| grep -vcE 'access_log[[:space:]]+off;'` | `0` | **Green** (5 lines, 5 `off`) |
| C-35 | A live request leaves the client address in no log | The end-to-end check that the configuration above actually holds. | `docs/verify.md` §12.1/4 | `0` | **None** (the live drill was not run) |
| C-36 | On onion the server cannot see the client IP | Onion is the only surface where the network layer cannot see the address either. | `docs/verify.md` §12.1 + `infra/tor/torrc` | `0` | **None** |
| C-37 | No claim against A1 in the clearnet copy | The clearnet text must not promise what the network layer cannot deliver. | text audit (`spec.md` §Claim texts) | no A1 claim appears | **Green (text)** |
| C-38 | "Yok ol" zeroes the `.db` and `-wal` within 5 s | Five seconds is a number a user can check with a stopwatch. | `mix test test/vanish_test.exs` | 33 tests, 0 failures | **Green** (20:30: 33 passed) |
| C-39 | VACUUM is not on the delete path | VACUUM rewrites the file on every delete and breaks the 5 s bound. | `grep -rn 'VACUUM' --include='*.ex' lib \| grep -vc maintenance` | `0` | **Red** — `lib/zifiri/vanish.ex:450` `Repo.query("VACUUM")` |
| C-40 | `auto_vacuum = INCREMENTAL` | Incremental vacuum shrinks the file at night without touching the delete path. | `grep -rn auto_vacuum --include='*.ex' lib config priv` | matches > 0 and `PRAGMA auto_vacuum` = 2 | **None** — 0 matches, the setting does not exist |
| C-41 | No backup / tombstone | A backup or a tombstone row is a second copy of what was deleted. | `mix test test/schema_test.exs` | no tombstone table in the allowlist | **Green** (19:52: 5/5) |
| C-42 | Block-level disk rests on LUKS | Block level is a LUKS reduction; the row states the reduction, not a guarantee. | `docs/verify.md` §9 | LUKS; no block-level guarantee | **None** |
| C-43 | The operator is the moderator; the decision record has `threshold = 1` | The single-key record is stated as it is, not dressed up as multi-party. | `mix test test/mod_test.exs` | 16 tests, 0 failures; `threshold` is 1 | **Green** (20:30: 16 passed) |
| C-44 | The audit chain catches later edits | The chain makes a later edit visible to anyone holding the head. | `mix test test/mod_test.exs` | edit/delete/reorder are all caught | **Green** (20:30: 16 passed) |
| C-45 | The audit chain does not prove who decided | Claiming a signer would put a signature claim where there is none. | text audit (`spec.md` §Moderation) | this claim is not made | **Green (text)** |
| C-46 | The identity line is 40 B / 64 base32 | A **71-character** line is short enough to copy and carries no public key. | `mix test test/identity_test.exs` | 27 tests, 0 failures | **Green** (20:28: 27 passed) |
| C-47 | `mailbox_id` is derived from the seed by HKDF | A derived id looks random without the seed and changes with the generation. | `mix test test/identity_test.exs` | matches a reference vector; changes with the generation | **Green** (20:28: 27 passed) |
| C-48 | "Write it on paper" is not claimed in v1 | 64 characters are not written by hand; claiming it would be a promise the format cannot keep. | text audit (`spec.md` §Identity line) | absent from the v1 copy | **Green (text)** |
| C-49 | The v2 word list is 27 words | A 12-word list carries 128 bits and cannot hold a 32-byte seed; **27 words** can. | `identity_test` v2 group | 27 words | **None** (v2 is not written) |

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
