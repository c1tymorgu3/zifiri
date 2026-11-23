# zifiri client — crypto core

Vanilla TypeScript + Vite. No framework, no third-party network requests.
Node 24 / npm 11.

## Commands

```sh
npm install
npm test        # vitest: vectors, padding, export/import
npm run typecheck
npm run build   # tsc --noEmit && vite build
npm run size    # gzip budget check (100 KiB for JS)
```

## Files

- `src/identity.ts` — seed generation, HKDF derivation, Ed25519 identity keys,
  `zifiri1...` export/import.
- `src/pad.ts` — fixed-size bucket codec (256 / 1024 / 4096 / 16384 bytes).
- `src/main.ts` — minimal UI; imports the core so the bundle is measured whole.
- `tests/` — vitest vectors and negative cases.
- `scripts/size.mjs` — post-build gzip budget report.

## Identity derivation

Everything is HKDF-SHA256 with an empty salt and a domain-separated `info`.
`u32be(i)` is the ownership index, big-endian.

| output | info | length |
| --- | --- | --- |
| `own_i` | `"zifiri/own/v1" \|\| u32be(i)` | 32 B |
| `id_sk` | `"zifiri/id/v1"` | 32 B (Ed25519 seed) |

`id_pk = Ed25519.getPublicKey(id_sk)`. The seed never leaves the client.
Known-answer vectors in `tests/identity.test.ts` are cross-checked against
`node:crypto` HKDF and Ed25519.

## Export format

```
zifiri1 + base32( seed(32) || generation(1) || u24be(next_i) || checksum(4) )
checksum = BLAKE2b-256(seed || generation || u24be(next_i))[0..4]
```

71 characters: a 7-character prefix and 64 base32 characters, no padding.
Byte-for-byte what `Zifiri.Identity.encode_line/3` writes, so a line moves
between this client and the server unchanged. There is no version byte and no
stored `mailbox_id`: the generation byte is the version, and the mailbox is
derived (`HKDF-SHA256(seed, "zifiri/mailbox/v1/" <> generation)[0..16]`).

Base32 is RFC 4648 without padding, written uppercase. Decoding is strict on
the alphabet, the length, the checksum and the canonical trailing bits, and
lenient on case and on the prefix: `zifiri1` and the older `zifir1` both load
(the latter with a warning). Corrupt input throws `IdentityImportError`.

## Padding

```
u32be(payload length) || payload || zero fill  ->  total = bucket size
```

`encode()` picks the smallest fitting bucket (or a larger explicit one).
`decode()` requires an exact bucket length, a length prefix that fits, and an
all-zero tail; otherwise it throws `PadError`.

## Security notes

- Seed stays in module scope; never on `window`, never in the DOM (plan §10.1).
- UI writes through `textContent` / `.value`; no `innerHTML`, no inline script.
- Bundle uses only `@noble/hashes` + `@noble/curves`.
