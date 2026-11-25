# zifiri — claims, tests, thresholds

Snapshot: 2026-11-25 14:35, `mix test` **404 passed, 4 excluded**, `cd client && npx vitest run` **300 passed**.

The anonymity claim is the product. Everything else in this repository exists to make
that claim checkable: a test, a command, a number, a date. What an instance publishes
is its operator's decision; this repository is about who can be identified, and about
whether that answer survives contact with the code.

A1 — the operator — is outside the model. The design assumes the operator complies and
minimises what compliance yields: no account, no sender column, **1/120** positions
inside a ten-minute bucket on the 1:1 plane (a room has no filler, so it has `k`), a
**4096 B** envelope that never varies, a **71-character** identity line that carries no
public key. A row below is either inside that model or explicitly outside it; the rows
outside it are named, not softened.

Every claim below comes from the contract in `docs/spec.md`. The `§` numbers in the
tables are the plan's section numbers; the plan itself is not in this repository and not in
its history. `docs/spec.md` is
the contract in force. This document holds the test, the threshold, why the claim is
load-bearing, and the **current** status of each one. If a
row says "green", the claim was run with the listed command and passed; "red" means it
was run and failed; "none" means there is no test and the claim is **unproven** — being
written in the plan does not make it true.

Every claim carries a stable ID (`C-01` … `C-51`) so that this file, `docs/verify.md`
and the README can be diffed against each other instead of against prose.

> **Provenance.** The per-row solo counts in §1 were taken on **2026-11-23**
> (12:24–15:26), on a checkout whose test tree compiles. The suite figures quoted
> here come from a re-run on **2026-11-25, 14:35**: `mix test` finished in 9.3 s with
> **404 passed, 4 excluded**; `cd client && npx vitest run` finished with **300 passed**
> in 15 files. Each row's count also comes from a solo `mix test test/<name>_test.exs`,
> and the bucket work added 17 tests — 11 in `mailbox_bucket_test`, 6 in
> `chat_bucket_test`.
> `decoy_shape_test` was rewritten to the 1:1 frame (C-04) and `api_surface_test`'s
> secret-mode row now expects a 1-message batch (C-50); no test was deleted.
> The 2026-11-22 snapshot this file used to carry is gone: it described a repository that
> no longer exists (a `posts` table in the allowlist, two compile breaks, a shared test
> DB) and none of its numbers can be reproduced.

Status dictionary:

| Status | Meaning |
|---|---|
| **Green** | Test exists, was run, passed (the count is given) |
| **Red** | Test exists, was run, failed (which test, and why) |
| **Flaky** | Test exists, passes or fails depending on conditions (why) |
| **None** | No test; the claim is unproven today |

| Status | Rows |
|---|---|
| Green | 40 |
| Flaky | 1 (C-11) |
| Red | 0 |
| None | 10 (C-07, C-13, C-21, C-29, C-31, C-35, C-36, C-40, C-42, C-49) |
| **Total** | **51** |

Nothing is written without a number, a date and a command.

---

## 0. The moment of measurement

On this checkout the repository is not being written to during the run: the test tree
compiles, the app boots once, and `Zifiri.DataCase` puts every test in a sandbox
transaction on a single database. The measurement is therefore two commands, not forty:

| Command | Result | Time |
|---|---|---|
| `mix test` | **404 passed, 4 excluded** (the 4 are the `:integration` e2e rows) | 9.3 s |
| `cd client && npx vitest run` | **300 passed**, 15 files | 1.9 s |

The per-file runs in §1 were taken one after another on the same checkout; each one
passed on its own, so a green row is not an artifact of the suite running together.

The parallel-rewrite window the previous snapshot described is closed. The transitional
`posts` table is gone from the migrated schema (C-19), `api_surface_test` compiles and
passes (22/22), and no run in this session produced a lock error or a compile error.

---

## 1. Claim table

| ID | Claim (plan §) | Why it matters | Test | Threshold | Today |
|---|---|---|---|---|---|
| C-01 | A bucket is ten minutes, target 120, aligned to the wall clock (§6.1) | The ten-minute bucket is the unit: it hides the moment of writing. The 1/120 figure belongs to 1:1 cover, not to a room batch. | `bucket_test` + `chat_bucket_test` (live room path) | a boundary instant opens the bucket; 120 target on the 1:1 plane; 3 room sends drain as one batch of 3 | **Green** — 14/14 + 6/6 |
| C-02 | The bucket drains on the clock, not on a count; the drain is shuffled; a closed bucket carries over (§6.1) | A drain on arrival order hands the observer the order of writes. | `bucket_test` + `chat_bucket_test` (live room path) | a full bucket does not drain early; stored order is not arrival order; empty bucket is a no-op | **Green** — 14/14 + 6/6 |
| C-03 | **1:1 only:** a non-empty bucket is completed to 120 with decoys; `fill(n)` = `n − real`; a room batch is never filled (§6.2) | On the 1:1 plane an empty or short bucket would say "one message was sent"; on a plaintext room the filler would only inflate the candidate set (C-50). | `mailbox_bucket_test` + `decoy_test` | 3 real → 120 rows (3 + 117 decoys), one transaction; `r>120` → 0; an empty bucket publishes nothing on either plane | **Green** — 11/11 + 15/15 |
| C-04 | **1:1 only:** a decoy is the same *frame* as a real 1:1 envelope — 4096 B, valid length prefix, zero tail; body random. Rooms publish no decoys. | If a decoy can be told apart by its frame, the padding is decoration and 1/120 is a fiction. The limit is named: the length prefix is plaintext, so the byte count is visible. | `mailbox_bucket_test` (incl. eph_pk point test) + `decoy_shape_test` | every decoy decodes `{:ok, _, 4096}`; 4096 B; no decoy body reads as text (printable ratio < 0.5 vs ~1.0 for text); ids random, no ordered pattern | **Green** — 11/11 + 6/6 |
| C-05 | The moment of writing is hidden: the real message's position inside the batch is uniform (§3.1) | The position inside the batch is the only clock an observer has left. | `timing_test` + `chat_bucket_test` (live room path) | uniform over 0..119 in 1000 samples (synthetic bucket; a room batch is k, C-50); an empty bucket loses nothing; the room path holds a message until the drain | **Green** — 3/3 + 6/6 |
| C-06 | The decoy key is per bucket, in RAM; the next bucket gets a different key (§6.3) | A key on disk lets a disk image separate real from decoy after the fact. | `decoy_test` | one key per bucket; not on disk; a fill of 20 carries 20 distinct keys | **Green** — 15/15 (the key is not written to disk; live memory is out of scope) |
| C-07 | Fast mode: < 1 s, the neighbourhood is the count of writes in the last sixty seconds (§3.4) | Fast mode is the default, so the last-sixty-seconds count is the number most users actually see. | `fast_mode_test` | p95 < 1 s; neighbourhood 5 | **None** — no `fast_mode_test` exists; the latency is unmeasured |
| C-08 | The 1:1 table has 5 columns; no sender/conversation/account column (§7.2) | A sender column puts a name back on the row the whole design removes. | `mailbox_test` | `PRAGMA table_info` is exactly 5 columns | **Green** — 30/30 |
| C-09 | 1:1 addressing is a 16 B HMAC tag; the key is not stored; the tag is deterministic and key-specific (§7.1) | The tag addresses a mailbox without storing the key that produced it. | `mailbox_test` | same key → same tag; different key → different tag | **Green** — 30/30 |
| C-10 | A 1:1 envelope is exactly 4096 B; the table rejects off-size rows too (§7.1) | A **4096 B** envelope that never varies keeps length out of the observation. | `mailbox_test` | module and trigger both refuse | **Green** — 30/30 |
| C-11 | 1:1 TTL is 72 hours; an expired envelope is not read and the sweeper deletes it (§7.3) | Expiry bounds how long a mailbox can be watched before it is empty by construction. | `mailbox_test` | default 72 h; sweeper every 5 min | **Flaky** — 30/30 today; 24/25 on 2026-11-22 (sweeper window on a slow machine, no fixed clock) |
| C-12 | 1:1 paging: 200 upper bound, the `since` cursor neither skips nor repeats, `ack` never deletes another box (§7.3) | A cursor that skips or repeats lets a reader infer traffic that is not there. | `mailbox_test` | 200 clamp; id monotonic | **Green** — 30/30 |
| C-13 | The recipient cannot open a decoy envelope (§7.4) | A decoy the recipient can open is a message; the recipient must see noise, not content. | — | even on a tag match, AEAD does not open | **None** |
| C-14 | 1:1 envelopes also accumulate in the bucket and are completed to 120 with decoys (§7.4) | Without the bucket, 1:1 writes its own arrival clock and 1/120 does not apply to it. | `mailbox_bucket_test` | 120 envelopes per bucket: 3 real + 117 decoys, one transaction | **Green** — 11/11 |
| C-15 | Listings: plaintext metadata, `owner_hash` not unique, `created_day` is a day, search `LIKE` is escaped, `erase/2` deletes all of an owner's listings (§8) | Listings are public by design; the claim is only that no account sits behind them. | `listings_test` (+ `api_surface_test` at the endpoint level) | 33 tests; 22 endpoint tests | **Green** — 33/33 + 22/22 |
| C-16 | With presence off there is no trace; `:unknown`; mutual for 5 min; turning it off deletes the row; ETS only (§9) | Presence is the one place where "off" must mean no row, not a row saying off. | `presence_test` | 31 tests; nothing written to disk or logs | **Green** — 31/31 |
| C-17 | Deletion level 1: the row goes, there is no tombstone, the file is untouched (§10.2) | Level 1 is the API promise: the row leaves every read path. | `vanish_test` | `{:ok, n}`; file size unchanged | **Green** — 33/33 |
| C-18 | Deletion level 2: `secure_delete` + WAL truncate + VACUUM; the body is found in neither the file nor the `-wal`; `busy` is reported honestly (§10.2) | Level 2 is the disk promise: the body is in neither the file nor the `-wal`. | `vanish_test` | `strings` scan clean; `freelist_count = 0` | **Green** — 33/33 |
| C-19 | Schema allowlist: only `listings`, `mailbox_envelopes`, `mod_audit`, `schema_migrations` (§7.2, §8) | An allowlist is how "no identity column" survives the next migration. | `schema_test` | an extra table/column fails the test | **Green** — 8/8 |
| C-20 | No logs (code level): no `Logger.info/debug`, `IO.inspect`, `dbg` in `lib/`; Ecto logging off (§11) | One `Logger.info` writes the body to a file the design says does not exist. | `no_log_test` + `architecture_test` | grep is empty | **Green** — 9/9 + 6/6 |
| C-21 | No logs (deployment level): proxy `access_log off`, container `logging: none`, crash dump off, no swap (§11) | Code can be clean while the proxy writes every request to disk. | drill | no log file in a live container | **None** |
| C-22 | The envelope is padded to 4 KB; its size does not vary with the input (§1, §4) | Size is the cheapest side channel; **4096 B** removes it. | `envelope_test` | every body is 4096 B | **Green** — 22/22 |
| C-23 | `owner_hash` is a peppered HMAC; the same owner gets a different hash on two writes (§5.3) | Without the pepper a hash is a lookup key; with it, it is a pseudonym. | `owner_test` | not unique; not computable without the pepper | **Green** — 18/18 |
| C-24 | IP/peer never reaches the application; `X-Forwarded-For`/`X-Real-IP` are stripped (§11) | If the application never sees the address, no code path can store it. | `transport_test` | header absent; peer is a fixed string | **Green** — 2/2 |
| C-25 | PoW: the challenge is single-use, the solution is bound to the envelope (§4.1) | A replayable challenge is a free write, and free writes are how a bucket is flooded. | `pow_test` | replay is refused | **Green** — 22/22 |
| C-26 | Chat writes nothing to disk; the room stream lives in RAM (§1) | Chat is the surface most likely to be logged; it writes nothing. | `chat_test` | no row in the DB | **Green** — 31/31 |
| C-27 | Fixed-size error responses: 404/413/500 are the same size, the path is not echoed (§11) | An error that echoes the path or changes size is a read oracle. | `leak_test` | every response is the same byte count | **Green** — 9/9 |

No row in this table is red.

---

## 2. The rows that were red on 2026-11-22

Both reds were closed by test and app code, not by loosening a test: `vanish_test` and
`leak_test` each kept its thresholds.

### 2.1 `vanish_test` — was 26/31, is 33/33

| Failing test (2026-11-22) | Error | What fixed it |
|---|---|---|
| `level 2 — erase_many/1 gives the pages back` | expected `{:ok, 0}`, got `{:ok, 200}` | the test inserted 200 rows into the transitional `posts` table; `insert_post/2` now creates the transitional table per test (`ensure_posts_table/0`) and drops it on exit |
| `level 2 — erase_many/1 leaves no plaintext body` | the scan cannot see the body at all | the row exists again, so the scan has something to look for |
| `level 2 — erase_many/1 a body that was not erased is still findable` | the scan says "clean" | same cause |
| `pending work calls every module that exports drop_owner/1` | `DropRecorder.reset/0` undefined | the test module is defined as `Zifiri.VanishTest.DropRecorder`; the call now uses the full name |
| `pending work drops each hash once` | same | same |

`Vanish.purge()` also returned `{:error, :busy}` once while a second `mix test` process
held the same `zifiri_test.db`. Alone, and in the full suite, the level 1/2 logic passes.

The order the code actually runs is asserted, not assumed:
`runs the deletes, then checkpoint, VACUUM, checkpoint in that order` and
`gives the pages back: a smaller file and an empty freelist` both pass inside the 33.

### 2.2 `leak_test` — was 5/9, is 9/9

| Failing test (2026-11-22) | Error | What fixed it |
|---|---|---|
| `every 404 is one size and never echoes the path` | response sizes `[21, 21, 16384, 16384, 16384]` | `lib/zifiri/error_view.ex` renders one fixed body per status; the endpoint no longer falls through to a routed 16 KB 404 |
| `an oversized body is refused, not crashed on` | `no "413" html template defined for Zifiri.ErrorView` | the 413 template exists and has the same length as the 404 |
| `a server fault answers in one size and names nothing` | `no "500" html template defined` | the 500 template exists |
| `a refused write is one size whatever the reason` | the 4xx/5xx body did not settle on one size | all four statuses now share one length |

---

## 3. The "none" rows — claims without evidence

These are written in the plan but have no test; today they are intent, not claims.

| Claim | Missing test | Why it matters |
|---|---|---|
| Fast mode < 1 s, 1/5 neighbourhood (C-07) | `fast_mode_test` | without the mode the user abandons silent mode; "80%" cannot be said without measuring. The default mode itself is C-30 and is green; only the latency is unmeasured |
| The recipient cannot open a decoy envelope (C-13) | a separate test inside `mailbox_test` | if decoy envelopes look like "you have a message" to the recipient, 1:1 breaks |
| No logs — deployment level (C-21) | `drill` (script + output) | `no_log_test` inspects code only; proxy/container/BEAM settings are unmeasured |

The listings HTTP surface is no longer on this list: `api_surface_test` compiles and
passes 22/22 today.

---

## 4. Known limits of the measurement

1. **The full suite is valid now.** One process, one DB, sandboxed tests:
   `mix test` → 404 passed, 4 excluded in 9.3 s, and the solo runs in §1 were taken on
   the same checkout. The 2026-11-22 failure mode (shared file, lock contention, 130 errors)
   does not recur on this checkout.
2. **Timing sensitivity remains.** The `mailbox` sweeper test fell in one 2026-11-22 run
   (5 min window plus a slow machine) and has passed since; there is no fixed-clock
   injection, so C-11 stays **Flaky** rather than green.
3. **Latency is unmeasured.** C-07's p95 has no test at all; nothing in this file claims
   a number for it.
4. **The live drill was not run.** C-21/C-35/C-36 are statements about a deployed
   container, and no container was deployed for this snapshot.

---

## 5. Post-decision claims — re-measured 2026-11-23 12:24–15:26

The six decisions in `docs/spec.md` turned into claims. The status column is the
output of the command run in this session; an unrun row is **None**, never a guess.

| ID | Claim | Why it matters | Test / command | Threshold | Status |
|---|---|---|---|---|---|
| C-28 | No published claim against A1 | A claim against the operator is unprovable; the model stops where the operator begins. | `grep -nE 'A1.*%[0-9]' docs/spec.md \| wc -l` | `0` | **Green** (0) |
| C-29 | When cover ships, the set against A1 is ≤ k | Cover narrows the set; the text may say "at most k" and nothing stronger. | `cover_test` | set ≤ k; the text says "at most k" | **None** |
| C-30 | Fast mode is the default | The default is the mode most users get, so it has to be the honest one. | `client/tests/start-mode.test.ts` | `START_MODE` is `"fast"` and seeds the shell (p95 is C-07, unmeasured) | **Green** (2 passed) |
| C-31 | "Send hidden" label + live neighbourhood counter | The button states the current neighbourhood instead of burying it in a footnote. | client test | the button reads `anonymity: N`; N = messages in the last 60 s, min 1 | **None** |
| C-32 | The application does not read IP / XFF / user-agent | Not reading the header is stronger than deleting it later. | `mix test test/transport_test.exs` | 2 tests, 0 failures | **Green** (12:26: 2 passed) |
| C-33 | No code outside `transport.ex` reads these headers | One exemption is a boundary; two are a hole. | `grep -rnE 'remote_ip\|x-forwarded-for' --include='*.ex' lib \| grep -v transport.ex \| wc -l` | `0` | **Green** (0) |
| C-34 | The nginx access log is off | A proxy log is a complete access record with an address on every line. | `grep -E '^[[:space:]]*access_log' infra/nginx.conf \| grep -vcE 'access_log[[:space:]]+off;'` | `0` | **Green** (5 lines, 5 `off`) |
| C-35 | A live request leaves the client address in no log | The end-to-end check that the configuration above actually holds. | `docs/verify.md` §12.1/4 | `0` | **None** (the live drill was not run) |
| C-36 | On onion the server cannot see the client IP | Onion is the only surface where the network layer cannot see the address either. | `docs/verify.md` §12.1 + `infra/tor/torrc` | `0` | **None** |
| C-37 | No claim against A1 in the clearnet copy | The clearnet text must not promise what the network layer cannot deliver. | text audit (`spec.md` §Claim texts) | no A1 claim appears | **Green (text)** |
| C-38 | "Vanish" zeroes the `.db` and `-wal` within 5 s | Five seconds is a number a user can check with a stopwatch. | `mix test test/vanish_test.exs` | 33 tests, 0 failures | **Green** (12:25: 33 passed) |
| C-39 | VACUUM runs on every erase (checkpoint → VACUUM → checkpoint) | The disk promise costs a full rewrite per erase; the order is what keeps the `-wal` clean too. | `mix test test/vanish_test.exs` | 33 tests, 0 failures; `runs the deletes, then checkpoint, VACUUM, checkpoint in that order` passes inside the file | **Green** (12:25: 33 passed) |
| C-40 | `auto_vacuum` is not set (the file is rebuilt on erase instead) | A pragma that was never set cannot shrink the file; the per-erase `VACUUM` is what returns the pages. | `grep -rn auto_vacuum --include='*.ex' lib config priv` | `0` matches and `PRAGMA auto_vacuum` = 0 | **None** — `auto_vacuum` is not set |
| C-41 | No backup / tombstone | A backup or a tombstone row is a second copy of what was deleted. | `mix test test/schema_test.exs` | no tombstone table in the allowlist | **Green** (8/8) |
| C-42 | Block-level disk rests on LUKS | Block level is a LUKS reduction; the row states the reduction, not a guarantee. | `docs/verify.md` §9 | LUKS; no block-level guarantee | **None** |
| C-43 | The operator is the moderator; the decision record has `threshold = 1` | The single-key record is stated as it is, not dressed up as multi-party. | `mix test test/mod_test.exs` | 18 tests, 0 failures; `threshold` is 1 | **Green** (18 passed) |
| C-44 | The audit chain catches later edits | The chain makes a later edit visible to anyone holding the head. | `mix test test/mod_test.exs` | edit/delete/reorder are all caught | **Green** (18 passed) |
| C-45 | The audit chain does not prove who decided | Claiming a signer would put a signature claim where there is none. | text audit (`spec.md` §Moderation) | this claim is not made | **Green (text)** |
| C-46 | The identity line is 40 B / 64 base32 | A **71-character** line is short enough to copy and carries no public key. | `mix test test/identity_test.exs` | 29 tests, 0 failures | **Green** (29 passed) |
| C-47 | `mailbox_id` is derived from the seed by HKDF | A derived id looks random without the seed and changes with the generation. | `mix test test/identity_test.exs` | matches a reference vector; changes with the generation | **Green** (29 passed) |
| C-48 | "Write it on paper" is not claimed in v1 | 64 characters are not written by hand; claiming it would be a promise the format cannot keep. | text audit (`spec.md` §Identity line) | absent from the v1 copy | **Green (text)** |
| C-49 | The v2 word list is 27 words | A 12-word list carries 128 bits and cannot hold a 32-byte seed; **27 words** can. | `identity_test` v2 group | 27 words | **None** (v2 is not written) |
| C-50 | A plaintext room publishes no decoys: a secret-room batch contains exactly the messages written in it, and the candidate author set is `k`, not 120 | Padding a plaintext room would make "120 candidates" a false sentence while the content is readable anyway; the batch must be counted, not assumed. | `chat_bucket_test` (+ `api_surface_test` at the endpoint) | 3 sends → 3 stored rows, bodies byte-identical, 3 distinct pubkeys; 1 secret send over the API → 1 entry | **Green** — 6/6 (+ 22/22) |
| C-51 | Room content is not confidential: secret mode hides the moment of writing, not what was written | If the text implied a room body was hidden, a user would confide in a channel the server reads in clear. | text audit (`docs/spec.md` §Two modes + §1; README §Rooms) | the sentence exists in the spec; no text claims room confidentiality or "120 candidates" for a room | **Green** — 2026-11-25: `grep -ni '120 candidates' docs/spec.md README.md` returns no match; README §Rooms says the bucket carries no decoys |

**Reading note.** C-38, C-39 and C-40 are three different sentences.
C-38 is the disk promise — no trace in the file or the `-wal` — and is green.
C-39 states what the code does: `checkpoint → VACUUM → checkpoint` on every
`erase_many/1` and `purge/0`, asserted query-by-query in `vanish_test`, and it is green.
The price is a full rewrite of the database per erase; `docs/decisions.md` records the
same trade-off. C-40 is the alternative that was **not** taken: `auto_vacuum` appears
nowhere in `lib/`, `config/` or `priv/`, so the file only shrinks through the
delete-path `VACUUM`. None of the three is softened into the others.

**Reading note (the decoy split).** C-03 and C-04 are 1:1 claims: the filler
completes a mailbox bucket to 120, and its frames are real 4096 B envelopes. They
are not room claims any more, because a plaintext room publishes no decoys at all
(C-50) — padding it would inflate the candidate set from `k` to 120 in prose
while the observer reads the batch anyway (C-51). `Zifiri.Chat.Decoy` still
exists and `decoy_test` still measures its key discipline (C-06), but nothing in
`lib/` calls it; the room's only bucket cost is the wait for the drain.

**Limit.** The full suite *was* run today (404 passed, 4 excluded, §0). Every row above
also has its solo run.

---

## 6. Reproducing a number

```bash
# one claim (solo evidence)
mix test test/bucket_test.exs
mix test test/decoy_test.exs
mix test test/decoy_shape_test.exs
mix test test/timing_test.exs
mix test test/mailbox_test.exs
mix test test/presence_test.exs
mix test test/listings_test.exs
mix test test/api_surface_test.exs
mix test test/schema_test.exs
mix test test/no_log_test.exs
mix test test/architecture_test.exs
mix test test/vanish_test.exs
mix test test/leak_test.exs
mix test test/identity_test.exs
mix test test/mod_test.exs
mix test test/transport_test.exs
mix test test/envelope_test.exs
mix test test/owner_test.exs
mix test test/pow_test.exs
mix test test/chat_test.exs
mix test test/api_test.exs
mix test test/chat_bucket_test.exs
mix test test/mailbox_bucket_test.exs

# the whole suite, and the client's
mix test
cd client && npx vitest run

# the decision rows in §5 that are not tests
grep -nE 'A1.*%[0-9]' docs/spec.md | wc -l
grep -rnE 'remote_ip|x-forwarded-for' --include='*.ex' lib | grep -v transport.ex | wc -l
grep -E '^[[:space:]]*access_log' infra/nginx.conf | grep -vcE 'access_log[[:space:]]+off;'
grep -rn auto_vacuum --include='*.ex' lib config priv   # expected: 0
mix run -e 'IO.inspect(Zifiri.Repo.query!("PRAGMA auto_vacuum").rows)'   # expected: [[0]]

# C-51 text audit: the room sentence is there, and nothing claims a room body is hidden
grep -c 'hides the moment of writing' docs/spec.md   # expected: 1
grep -ni '120 candidates' docs/spec.md README.md     # expected: no match
```

The second C-51 command is the audit, not a formality. On 2026-11-23 it returned two
README lines ("an observer has 120 candidates", "gives 120 candidates whether one person
posts or twenty"), which is why C-51 was **None**. The release pass rewrote both; on
2026-11-25 the same command returns no match and the row is green.

A change that turns a row green is recorded in this document together with the output
of the same command; the words "done" on their own are not accepted.
