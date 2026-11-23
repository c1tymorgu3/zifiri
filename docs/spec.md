# zifiri — specification

Target: a measured number against a defined adversary; A1 is outside the model.

A claim is not absolute, it is measured: a number means nothing until the
adversary is defined. This file writes both together. Two numbers stand apart:

- **A2/A3** (passive observer, fake user): bucket + decoy, **99.2%**.
- **A1** (operator): **outside the model**. The design assumes the operator
  complies and, when they do, keeps what they get to the minimum: no account,
  no sender column, ciphertext and hashes. Once cover is live and measured the
  claim becomes "set ≤ k" — not a fixed percentage.

## Adversary (accepted)

| class | capability | claim |
|---|---|---|
| A1 operator | database, disk, deploy key. Does not resist a constitutional demand. | **no claim on the time of writing or on IP**; after cover, "set ≤ k". The absence of a writer column is a separate claim (schema test) |
| A2 passive observer | watches traffic, sees packet size and time | bucket padding + decoy, 99.2% |
| A3 fake user | unlimited keys, can pay PoW, can join the pool | the bucket is filled to a fixed size; a decoy's origin is unknown |
| A4 curious reader | reads the content, infers from style | **no claim** — if the content describes itself there is no fix |

Out of scope: a global passive observer (both ingress and egress), device
seizure, an adversary who knows the user personally, legal compulsion.

## Decoy does not work against A1 — a limit of the design

Whoever produces the decoy can tell it apart; this is not a defect, it is where
the model ends:

- **The server produces its own decoys.** Whoever writes the padding
  distinguishes the real item from the decoy; the decoy travelling the same
  path, with the same PoW and the same envelope, does not change that. So
  padding **does not protect against A1**.
- **The set against A1 is k**, the number of clients that sent cover in that
  10-minute window. In a room of 3, k = 3. "99%" would only be true once
  k ≥ 120; that is why no percentage is written for A1.
- Today there is **no cover**; for A1 the published text contains no claim.
  Once cover is live and measured the claim becomes **"set ≤ k"**. The k shown
  is an **upper bound** (A3 can inflate it with fake clients): the text says
  "at most k", not "k people".
- **On the message plane (72 h TTL, mailbox written to disk) no claim against
  A1 is written.** Cover stays on the room/bucket plane (memory, 15 min).

Rules for cover to work (in force once cover is live):

1. Cover travels the same path as a real message: same PoW, same envelope,
   same size bucket, same signature structure.
2. The real message takes the **place** of that window's cover; there is no
   extra send.
3. Cover is on by default; a setting may turn it off.
4. The cost is PoW, not bandwidth: 576 KB/day, under 1% of the bucket
   broadcast. The assumption of 0.35–3.5 s per write in a browser was **not
   measured**.

## The number: bucket size = anonymity set

Publishing happens in **buckets**. Every bucket is filled to a fixed size with
decoys, then shuffled and published. The observer sees `n` messages in the
bucket and picks the real one with probability 1/n.

| bucket | probability | traffic (4 KB × n / 10 min) | per day |
|---|---|---|---|
| 32 | 96.9% | 128 KB / 10 min | 18 MB |
| 64 | 98.4% | 256 KB | 37 MB |
| **120** | **99.2%** | **480 KB** | **69 MB** |
| 256 | 99.6% | 1 MB | 147 MB |
| 1000 | 99.9% | 4 MB | 576 MB |

**Choice: 120.** 99.2% at 69 MB a day. 99.9% needs 8× the traffic; if that
money is spent anywhere it goes to code, not to decoys.

Note: this number answers "which message is yours" **for A2/A3**. The question
"who are you" already has no answer — no account, no IP, no session. The two
questions are separate; on the second the ratio is 100%. For A1 this table does
not hold (see above).

## Two modes — fast is the default

Chat has no single right answer: some want to speak at once, some want not to
be seen. The product stands on its first 20 users; a chat that waits 10 minutes
is not a chat. So **the default is fast mode**.

- **Fast (default):** the message goes out at once. There is no cover pool: the
  anonymity you have is the number of writes in the last sixty seconds, and the
  button prints it. Latency < 1 s. Warning text: "fast send · anonymity right now: N".
- **Secret send:** the name of silent mode in the interface. The message enters
  the 10-minute bucket, the bucket is filled to 120 with decoys, shuffled and
  published. Latency ≤ 10 min. Warning: "your moment of writing is ~99%
  hidden".

The trade-off is written on the button — not hidden:

- Fast: **"fast send · anonymity right now: 1"**
- Secret send: **"secret send · anonymity: 120 · ≤ 10 min"**

The number shown in fast mode is **the message count of the last 60 seconds**;
with no traffic it is 1. Fast being the default does not make the claim
misleading.

The mode is asked once in the client and then remembered (memory only; no
localStorage).

## Claim texts — clearnet and onion differ

Two separate texts; the leading claim is **"no identity"**, because it is true
and provable on both clearnet and onion. "No IP" is a secondary claim specific
to onion. Being onion-only would cut the user count to single digits and make k
worthless; the two surfaces share the same rooms.

**Clearnet:**

> "No account, no e-mail, no cookie; no author on the row; the application does
> not read or store IP, user-agent or X-Forwarded-For. The network layer
> (nginx, the kernel, the hosting provider) can see your IP and zifiri cannot
> prevent that."

**Onion (in addition):**

> "In addition, the server cannot see you at the IP level either."

On clearnet "no IP" cannot be proven: nginx, the kernel or the provider see the
IP. That is why the clearnet text does not say "the author is unknown", it says
"no identity is stored". **On clearnet there is no claim against A1**: the
operator can put the time of a request and its IP side by side (especially in
fast mode).

## 1:1 — there is no sender to begin with

- Envelope: `recipient_tag(16) | eph_pk(32) | nonce(12) | ct | tag(16)`, 4 KB
  bucket.
- The server sees the mailbox `HMAC(pepper, recipient_pk)`; there is **no**
  sender field.
- The bucket rule applies here too: on secret send the envelopes collect in the
  10-minute bucket and are completed to 120 with decoy envelopes. The recipient
  fetches the bucket, cannot open the decoys (no key), and opens the real one.
  To the recipient a decoy is noise; to the observer it is an equal candidate.
- Presence (§P0-4) is coarse and mutual; switch it off and no trace remains.

## Listings — a narrow claim

A listing is permanent and public; the moment of publishing is not hidden. The
claim: **there is no account, IP or e-mail behind the listing**. `owner_hash`
cannot be resolved without the pepper. The same owner may post several
listings; deletion takes all of them.

## Deletion — claim and mechanism

The claim sentence, N = 5:

> "At most **5 s** after 'vanish' the content is zeroed in the database file
> and in the WAL; there is no backup and no tombstone; block-level disk rests
> on LUKS."

- **What provides the guarantee:** `PRAGMA secure_delete=ON` (a deleted cell is
  zeroed in its page) + `wal_checkpoint(TRUNCATE)` (old page images leave the
  WAL). A single GenServer "vanish" queue collects deletions in a ~1 s window,
  runs `DELETE` in one transaction, then checkpoints.
- **VACUUM left the deletion path.** Rewriting the whole DB on every "vanish"
  (temporary ~2× disk) breaks the p95 < 2 s threshold. VACUUM runs only in
  **nightly maintenance** and is not part of the deletion claim.
- **`auto_vacuum=INCREMENTAL`**: the DB is created that way from the start;
  at night `PRAGMA incremental_vacuum(N)` shrinks the file.
- **No backup and no tombstone.** No "deleted" row is written.
- **Block-level disk rests on LUKS**; no physical-erase guarantee is given on
  SSDs, and this sentence does not hide that.
- N = 5 is today's starting point: 1 s window + checkpoint. If p95 stays ≥ 2 s
  the window goes 5 → 30 s and N = 30 is written. There is no return to VACUUM.

## Moderation — "the operator is the moderator"

One mode, written plainly: **"The operator is the moderator."**

- In a one-person project, at a stage with no users, there are no 2/3 signers.
  If the same person holds all three keys, a multisig is fake assurance; a B
  done at the wrong time is worse than an A.
- Community voting is ruled out: in a system without accounts a vote = PoW, and
  the attacker mints keys.
- The decision record is written from the start with a `threshold` and
  signature field; today it is **1/1**. Moving to 2/3 does not break the chain
  format.

**What the audit chain does not prove:** the chain shows that decisions were
**not altered afterwards**. It does not show **who** made a decision; it does
not show that a decision was correct; it does not show that the signers cannot
see each other (the collecting server is the operator and sees the signers —
this is accepted as A1).

## Identity line — 40 B, 64 base32

`mailbox_id` is not chosen at random: it is derived from the seed with
**HKDF-SHA256** (input: the generation counter) and looks random to an outside
observer. That is why the line is short.

| field | bytes |
|---|---|
| seed | 32 |
| generation (counter) | 1 |
| counter | 3 |
| checksum | 4 |
| **total** | **40** → **64 base32 characters** |

With the `zifiri1` prefix it is **71** characters; one line on screen.

- `mailbox_id = HKDF(seed, "zifiri/mailbox/v1/" + generation)`. For anyone who
  does not know the seed the output is random; the property "the recipient's
  public key never reaches the server" is unchanged. The only extra benefit of
  randomness was being able to change it after a leak; that is covered by the
  1-byte **generation** counter.
- **v1: copy-paste + download as a file.** "Write it on paper" is **not
  claimed** in the v1 text; 71 characters are not written by hand, and 64 is
  not practical as a disaster backup either.
- **v2: word list.** The same bytes, the same checksum logic, BIP39 English
  (2048 words), **27 words** (27 × 11 = 297 bits = 288 + 9 checksum). 12 words
  carry 128 bits and do not carry a 32 B seed.

## Measurable targets (acceptance criteria)

| # | claim | test | threshold |
|---|---|---|---|
| 1 | The bucket always fills to 120 | `decoy_fill_test` | every bucket `n = 120` |
| 2 | A decoy is genuinely indistinguishable | `decoy_shape_test` | same size, envelope, signature |
| 3 | The moment of writing is hidden (secret send) | `timing_test` | 1 in 120 candidates |
| 4 | Fast mode works and is the default | `fast_mode_test` | latency < 1 s; fast is the default |
| 5 | 1:1 has no sender | `schema_test` | no `sender` column |
| 6 | The recipient cannot open a decoy | `mailbox_test` | an attempt to open a decoy errors |
| 7 | There are no logs | `drill` | `/var/log` empty, no nginx access_log |
| 8 | "Vanish" zeroes the file and the WAL within 5 s | `vanish_test` | no trace in `.db` + `-wal`; `auto_vacuum = 2`; no VACUUM on the deletion path |
| 9 | No trace while presence is off | `presence_test` | no table/row |
| 10 | The set against A1 (once cover is live) | `cover_test` | set ≤ k; the text says "at most k" |
| 11 | The identity line is 64 base32 | `identity_test` | 40 B → 64 characters; `mailbox_id` from HKDF |
| 12 | The application does not read IP headers | `transport_test` | `remote_ip`/`x-forwarded-for` are not read |

## Removed (carried over from v4)

Subject tree, `parent_id`, the k=5 pool, day granularity, turn identity, the
"queued" state. There is no wait on listings; the bucket applies only to chat
and 1:1.

## Work order

1. Schema: `listings`, `mailbox_envelopes`, `room_messages` (memory), `posts`
   are deleted.
2. Decoy engine + bucket timer (10 min) + fill tests.
3. Sealed-sender client crypto + mailbox endpoints + 72 h TTL.
4. Listings: list, filter, ownership, deletion.
5. Client: three tabs + mode selector (fast by default, "secret send") + live
   neighbourhood counter + presence switch.
6. Drills/load tests against the new surface.
7. The "vanish" queue: one GenServer, `secure_delete` +
   `wal_checkpoint(TRUNCATE)`, `auto_vacuum=INCREMENTAL`; VACUUM moves to
   nightly maintenance.
8. `mailbox_id` HKDF derivation + the 40 B / 64-character line.
9. A `threshold` field in the decision record (1/1 today).
10. Client cover + mobile PoW measurement (the A1 claim is written after this
    measurement).
