<p align="center">
  <img src="assets/banner.jpg" alt="zifiri" width="100%">
</p>

<p align="center">
  <a href="https://github.com/c1tymorgu3/zifiri/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/c1tymorgu3/zifiri/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="Elixir 1.20" src="https://img.shields.io/badge/Elixir-1.20-4B275F?style=flat-square&logo=elixir&logoColor=white">
  <img alt="Phoenix 1.8" src="https://img.shields.io/badge/Phoenix-1.8-FD4F00?style=flat-square&logo=phoenixframework&logoColor=white">
  <img alt="SQLite" src="https://img.shields.io/badge/SQLite-003B57?style=flat-square&logo=sqlite&logoColor=white">
  <img alt="680 tests" src="https://img.shields.io/badge/tests-680%20passing-brightgreen?style=flat-square">
  <img alt="71 KiB gzip" src="https://img.shields.io/badge/bundle-71%20KiB%20gzip-blue?style=flat-square">
  <img alt="11 claims" src="https://img.shields.io/badge/claims-11%20measured-yellow?style=flat-square">
  <img alt="AGPL-3.0" src="https://img.shields.io/badge/license-AGPL--3.0-orange?style=flat-square">
</p>

<h1 align="center">zifiri</h1>

<p align="center">A message board where the database cannot answer "who wrote this".</p>

---

No account, no email, no session, no cookie, no author column. You generate a key in the
browser, post, and the server keeps a row that has no path back to you.

The part worth reading is not the missing login form. It is the number behind it. A message
does not go out when you press send. It joins a ten-minute bucket, the bucket is padded with
decoys to exactly 120 entries, and the whole bucket is shuffled before anyone can read it.
Somebody watching the wire has 120 candidates and no way to tell which one you wrote.

Every claim below carries an ID, and every ID has a command that can refute it. If a claim
cannot be checked, it does not belong in this file.

## Sixty seconds

```bash
git clone https://github.com/c1tymorgu3/zifiri && cd zifiri
make check          # format, compile with warnings as errors, 383 backend and 297 client tests
mix ecto.create && mix ecto.migrate && mix phx.server
```

Open `http://localhost:4000`. The first screen asks for nothing: the identity lives in the tab
until you export it as one line of text.

## Three surfaces

| Surface | What it is | Where it lives |
|---|---|---|
| **Rooms** | one public room, 500-message ring buffer, 15-minute retention | RAM only. No table, no file, no log line. Restart is a wipe |
| **Messages** | one-to-one, 4096-byte sealed envelopes, addressed by a random 16-byte mailbox id | `mailbox_envelopes`, 72-hour TTL, no sender column exists |
| **Listings** | classifieds with plaintext title, price and category, and a padded body | `listings`, UTC day, non-unique `owner_hash` |

## What it does not hide

Three things, stated once so nobody has to discover them later.

- On clearnet, the path in front of the application sees your IP. Run the onion service and it
  does not.
- An operator can recognise decoy traffic their own server generated. The design assumes they
  comply and minimises what compliance yields: ciphertext and a list of hashes.
- Content that describes its author defeats every design in this repository. No amount of
  padding fixes a sentence that says where you work.

<details>
<summary><b>How a write travels</b></summary>

```
browser                    server                      disk
───────                    ──────                      ────
pad to bucket   ──────►    decode + verify padding     nothing yet
solve PoW       ──────►    redeem single-use challenge
                           enqueue in 10-min bucket
                           at the boundary: fill to 120 with decoys,
                           shuffle, publish the whole bucket
                                                       listings / mailbox rows
```

The exchange is a challenge the server issued, bound to one body and one owner. It is spent on
first use, so one solved nonce buys one write, not a season of them. Difficulty is 17 bits by
default and rises with queue depth; the number comes from a measurement, not an estimate.

</details>

<details>
<summary><b>How deletion actually deletes</b></summary>

Two clicks: erase token list, `DELETE`, done.

Rows are removed, `secure_delete` zeroes the freed pages instead of only unlinking them, and
the WAL is truncated and checkpointed. A canary written before the erase is unreadable in both
the `.db` and the `-wal` file within milliseconds; the measurement is 8 to 12 ms for fifty
listings. `VACUUM` runs at night and is not part of the promise, because it rewrites the whole
file and would stall every writer.

There are no tombstones and no backups. A backup is a copy you cannot delete.

</details>

## Claims

Eleven claims, each with an ID and a test. [docs/claims.md](docs/claims.md) is the registry,
[docs/verify.md](docs/verify.md) carries the command, and CI diffs the two ID sets so they
cannot drift apart.

| ID | Claim |
|---|---|
| C-01 | A writer has no account, no session and no cookie |
| C-02 | A published row has no author field |
| C-03 | The application never reads an IP or a user agent |
| C-04 | Every write spends a single-use proof of work |
| C-05 | Request bodies are padded to one of four bucket sizes |
| C-06 | A bucket is filled to 120 entries and shuffled |
| C-07 | A one-to-one message stores no sender |
| C-08 | No access log is written, at any layer |
| C-09 | Erase leaves nothing readable on disk |
| C-10 | The client makes no third-party request |
| C-11 | The client bundle stays under 100 KiB gzip |

## Architecture

```
Phoenix endpoint ── unix socket ── nginx (access_log off, headers stripped)
      │
      ├─ Pow.Challenge   single-use, body and owner bound
      ├─ Envelope        four buckets, zero padding, no length leak
      ├─ Bucket         10 minutes, decoy fill, shuffle at the boundary
      ├─ Chat.Store     RAM ring buffer, 500 messages, 15 minutes
      ├─ Mailbox        sealed envelopes, random id, 72-hour TTL
      ├─ Listings       classifieds, owner token, no seller record
      └─ Vanish         delete, secure_delete, checkpoint, night vacuum
               │
            SQLite (one file, one writer, LUKS underneath)
```

<details>
<summary><b>Repository map</b></summary>

```
lib/zifiri/      33 modules, 6.2k lines
test/            383 tests, 7k lines (more test than code, on purpose)
client/          vanilla TypeScript, no framework, 297 tests
infra/           nginx, Dockerfile, compose, onion, systemd units, harden.sh
scripts/         drills, measurements, e2e, publish gate
docs/            spec, claims, verify, measurements, decisions
```

</details>

## Documentation

- [docs/spec.md](docs/spec.md) the specification: surfaces, threat model, mechanisms
- [docs/claims.md](docs/claims.md) every claim, its test, its threshold
- [docs/verify.md](docs/verify.md) the command that refutes each claim
- [docs/measurements.md](docs/measurements.md) measured numbers with the scripts that produced them
- [docs/decisions.md](docs/decisions.md) what changed and why, in one page
- [CONTRIBUTING.md](CONTRIBUTING.md) how to run CI locally, and the two questions every patch answers

## License and credits

AGPL-3.0. If you run a modified version as a service, publish the source.

Built by [c1tymorgu3](https://c1tymorgu3.com).
