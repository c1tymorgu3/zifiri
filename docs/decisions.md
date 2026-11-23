# zifiri — decisions

One page. Each row is **decision · why · instead of**. The binding contract is
`docs/spec.md`; earlier revisions are archived and their claims are not current.

## Scope and claims

| Decision | Why | Instead of |
|---|---|---|
| Three planes: room / 1:1 / listing; no fourth plane | One anonymity sentence cannot be said for three surfaces at once: on a listing the moment of publishing is already public, in chat time alone leaks identity | forum, subject tree, voting, the `k = 5` pool, bulk publish |
| Each plane carries its own claim | Listing "no identity", 1:1 "no sender", room "moment of writing hidden"; saying one sentence for all three would be a lie | one general "anonymity" claim |
| No claim against A1 (the operator) | The server produces the decoys, so whoever writes the padding can tell them apart; the set against A1 is k, the number of clients that sent cover in that 10-minute window, and "99%" is only true once k ≥ 120 | v4's "decoys are indistinguishable on disk" |
| A2/A3 claim: bucket + decoy, bucket 120 (99.2%, 69 MB/day) | A number means nothing without a defined adversary; 99.9% costs 8× the traffic for a fraction of a percent, and that money is better spent on code | a fixed percentage written for A1; the self-filling pool and "≈1/n" (unmeasurable, wrong against an active attacker) |
| Default fast mode, "secret send" as the second mode, anonymity printed on the button | A chat that waits 10 minutes is not a chat, and anonymity's fuel is users; the trade-off is written, not hidden: "fast send · anonymity right now: 1" | silent mode as the default |
| Two claim texts, clearnet and onion; "no identity" leads | "No identity" is true and provable on both surfaces; "no IP" cannot be proven on clearnet because nginx, the kernel and the provider see it | a single onion-only text |
| Cover runs in the client, tab open only | No localStorage and no background worker, so a client-side cover is the honest option; the cost is PoW, not bandwidth (576 KB/day, not measured) | counting server-side padding as protection against A1 |
| No defensive framing; A1 is an engineering limit, not an apology | "We do not share leaks" weakens a claim that can be counted, and puts argument ahead of evidence | "not a leak archive", "no doxxing", "at your own risk" |
| Software only; no service, domain or onion address in the README | Whoever runs an instance is its operator and moderator; a published address cannot be taken back, and adding one later costs a paragraph | promising a hosted service |

## Deletion

| Decision | Why | Instead of |
|---|---|---|
| `secure_delete` + `wal_checkpoint(TRUNCATE)` behind one GenServer queue, N = 5 s | A ~1 s window collects deletions into one transaction, then the checkpoint; cell zeroing plus WAL truncation is the guarantee | "deletion depends on VACUUM" |
| VACUUM leaves the deletion path and runs in nightly maintenance; `auto_vacuum=INCREMENTAL` | Rewriting the whole DB on every vanish (temporary ~2× disk) breaks the p95 < 2 s threshold | VACUUM on every delete |
| No backup, no tombstone; block-level disk rests on LUKS | A "deleted" row is a record of the thing you deleted | tombstone rows |

## Moderation

| Decision | Why | Instead of |
|---|---|---|
| "The operator is the moderator", recorded at 1/1, with a `threshold` field | A one-person project has no 2/3 signers; three keys in one hand is fake assurance, and a B done at the wrong time is worse than an A | 2/3 multisig and community voting (a vote = PoW, and the attacker mints keys) |

## Identity

| Decision | Why | Instead of |
|---|---|---|
| 40 B / 64 base32 characters, `mailbox_id = HKDF-SHA256(seed, "zifiri/mailbox/v1/" + generation)`, prefix `zifiri1` → 71 characters (`zifir1` still parses as legacy) | 90 characters are not written by hand and 64 is not practical as a disaster backup; a 1-byte generation counter covers rotation after a leak | a random 128-bit `mailbox_id` and a 90-character line |
| v1 is copy-paste plus file download; v2 is a BIP39 word list of 27 words | 27 × 11 = 297 bits = 288 + 9 checksum; 12 words cannot carry a 32 B seed | claiming "write it on paper" in v1 |

## Repository

| Decision | Why | Instead of |
|---|---|---|
| AGPL-3.0-or-later | A modified instance that logs silently must publish its source to its users; the cost is corporate users | MIT, or a repo with no license (nobody may use it) |
| English showcase, every claim bound to a `C-nn` ID | One ID set turns translation drift into a single diff in `make check` | free prose in two languages |
| One credit line: `Credits: c1tymorgu3 (c1tymorgu3.com)` | The profile and the domain are already public; anonymous publishing is not required | a separate operator/moderator line |
