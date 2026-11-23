import { describe, expect, it } from 'vitest';
import { ed25519 } from '@noble/curves/ed25519.js';
import { blake2b } from '@noble/hashes/blake2.js';
import { bytesToHex } from '@noble/hashes/utils.js';
import {
  BODY_LENGTH,
  EXPORT_PREFIX,
  IdentityImportError,
  LEGACY_EXPORT_PREFIX,
  LINE_LENGTH,
  MAILBOX_ID_LENGTH,
  MAX_GENERATION,
  MAX_NEXT_I,
  SEED_LENGTH,
  createIdentity,
  deriveIdentityKeys,
  deriveMailboxId,
  deriveOwnToken,
  deriveOwnTokens,
  exportIdentity,
  importIdentity,
  ownTokenHex,
} from '../src/identity';

// Known-answer vectors, cross-checked against node:crypto HKDF and Ed25519.
const VECTOR_SEED = Uint8Array.from({ length: 32 }, (_, i) => i);
const OWN_0 = 'cb143734da2257972013a30c8348dad314785f823145e8a2ac4b2a9830c97bc6';
const OWN_1 = 'dd7de46ce05659e5fe971dc34d6ed1bd697c0ba4df3f01f59c23521bc69f28c5';
const OWN_MAX = 'db74c3252d5c02af800a95e0ca7c34462192e82ed0462483aa136ca0713e1022';
const ID_SK = 'ca95351e88c6a10abf89297ba72cd65a7e846ca8b8e387f98de854729cc5ca28';
const ID_PK = '8d28e1cb3a8871a59439f9f0f2be1052d890d66945a33dc26182a369cd1b9f3c';

// `Zifiri.Identity.encode_line/3` produces these same 71 characters for the
// same inputs — the two implementations are checked against each other.
const GOLDEN_NEXT_7 =
  'zifiri1AAAQEAYEAUDAOCAJBIFQYDIOB4IBCEQTCQKRMFYYDENBWHA5DYPQGAAAA7LLVKBQ';
const GOLDEN_NEXT_MAX =
  'zifiri1AAAQEAYEAUDAOCAJBIFQYDIOB4IBCEQTCQKRMFYYDENBWHA5DYPQH77774AKWMK4';

// BLAKE2b-256(seed 0..31 || generation 0 || next_i 0)[0..4].
const CHECKSUM_0 = 'af9f7a52';

// HKDF-SHA256(seed, info = "zifiri/mailbox/v1/" || generation)[0..15].
const MAILBOX_0 = '76a0c7c98cd50e5cad1bdb1d7c15d78c';
const MAILBOX_3 = 'ecc162e71f7b721be0406f14d130706b';
const MAILBOX_5 = '9600094e4a091869f47d8638eac69d61';

function flipChar(text: string, position: number): string {
  const replacement = text[position] === 'a' ? 'b' : 'a';
  return text.slice(0, position) + replacement + text.slice(position + 1);
}

describe('seed', () => {
  it('generates a fresh 32-byte seed', () => {
    const a = createIdentity();
    const b = createIdentity();
    expect(a.seed).toHaveLength(SEED_LENGTH);
    expect(a.nextI).toBe(0);
    expect(a.generation).toBe(0);
    expect(bytesToHex(a.seed)).not.toBe(bytesToHex(b.seed));
  });
});

describe('deriveOwnToken', () => {
  it('matches the fixed vectors', () => {
    expect(ownTokenHex(VECTOR_SEED, 0)).toBe(OWN_0);
    expect(ownTokenHex(VECTOR_SEED, 1)).toBe(OWN_1);
    expect(ownTokenHex(VECTOR_SEED, 0xffffffff)).toBe(OWN_MAX);
  });

  it('is deterministic and 32 bytes', () => {
    const a = deriveOwnToken(VECTOR_SEED, 42);
    const b = deriveOwnToken(VECTOR_SEED, 42);
    expect(a).toHaveLength(32);
    expect(a).toEqual(b);
  });

  it('separates indexes and seeds', () => {
    const other = new Uint8Array(32).fill(7);
    const tokens = new Set(
      Array.from({ length: 32 }, (_, i) => ownTokenHex(VECTOR_SEED, i)),
    );
    expect(tokens.size).toBe(32);
    expect(ownTokenHex(other, 0)).not.toBe(OWN_0);
  });

  it('rejects malformed seeds and indexes', () => {
    expect(() => deriveOwnToken(new Uint8Array(31), 0)).toThrow(TypeError);
    expect(() => deriveOwnToken(new Uint8Array(33), 0)).toThrow(TypeError);
    expect(() => deriveOwnToken('not bytes' as unknown as Uint8Array, 0)).toThrow(TypeError);
    expect(() => deriveOwnToken(VECTOR_SEED, -1)).toThrow(RangeError);
    expect(() => deriveOwnToken(VECTOR_SEED, 1.5)).toThrow(RangeError);
    expect(() => deriveOwnToken(VECTOR_SEED, 2 ** 32)).toThrow(RangeError);
  });

  it('derives ranges for the disappear sweep', () => {
    const range = deriveOwnTokens(VECTOR_SEED, 5, 3);
    expect(range.map((token) => bytesToHex(token))).toEqual([
      ownTokenHex(VECTOR_SEED, 5),
      ownTokenHex(VECTOR_SEED, 6),
      ownTokenHex(VECTOR_SEED, 7),
    ]);
    expect(deriveOwnTokens(VECTOR_SEED, 0, 0)).toEqual([]);
    expect(() => deriveOwnTokens(VECTOR_SEED, 0, 4097)).toThrow(RangeError);
    expect(() => deriveOwnTokens(VECTOR_SEED, 0xffffffff, 2)).toThrow(RangeError);
  });
});

describe('deriveIdentityKeys', () => {
  it('matches the fixed vector', () => {
    const keys = deriveIdentityKeys(VECTOR_SEED);
    expect(bytesToHex(keys.secretKey)).toBe(ID_SK);
    expect(bytesToHex(keys.publicKey)).toBe(ID_PK);
  });

  it('is deterministic and signs verifiably', () => {
    const keys = deriveIdentityKeys(VECTOR_SEED);
    const again = deriveIdentityKeys(VECTOR_SEED);
    expect(keys.publicKey).toEqual(again.publicKey);

    const message = new TextEncoder().encode('zifiri');
    const signature = ed25519.sign(message, keys.secretKey);
    expect(ed25519.verify(signature, message, keys.publicKey)).toBe(true);
    expect(ed25519.verify(signature, new TextEncoder().encode('zifirj'), keys.publicKey)).toBe(false);
  });
});

describe('export/import', () => {
  it('matches the fixed export vectors', () => {
    expect(exportIdentity(VECTOR_SEED, 7, 3)).toBe(GOLDEN_NEXT_7);
    expect(exportIdentity(VECTOR_SEED, MAX_NEXT_I, 3)).toBe(GOLDEN_NEXT_MAX);
  });

  it('is exactly 71 characters: 7-character prefix plus 64 base32', () => {
    const text = exportIdentity(VECTOR_SEED, 7, 3);
    expect(EXPORT_PREFIX).toBe('zifiri1');
    expect(LINE_LENGTH).toBe(71);
    expect(BODY_LENGTH).toBe(64);
    expect(text.length).toBe(71);
    expect(text.slice(EXPORT_PREFIX.length)).toHaveLength(64);
    expect(text).toMatch(/^zifiri1[A-Z2-7]{64}$/);
    expect(text).not.toMatch(/\s/);
  });

  it('round-trips seed, next_i and generation', () => {
    for (const nextI of [0, 1, 7, 1234, MAX_NEXT_I]) {
      for (const generation of [0, 1, 3, MAX_GENERATION]) {
        const restored = importIdentity(exportIdentity(VECTOR_SEED, nextI, generation));
        expect(bytesToHex(restored.seed)).toBe(bytesToHex(VECTOR_SEED));
        expect(restored.nextI).toBe(nextI);
        expect(restored.generation).toBe(generation);
        expect(restored.warnings).toEqual([]);
      }
    }
  });

  it('lays the body out as seed | generation | next_i | BLAKE2b-256 checksum', () => {
    const text = exportIdentity(VECTOR_SEED, 0, 0);
    const restored = importIdentity(text);
    expect(bytesToHex(restored.seed)).toBe(bytesToHex(VECTOR_SEED));

    // Read the 40 bytes back the way the server does: 32 seed, 1 generation,
    // 3 next_i, 4 checksum. The checksum is the first four bytes of
    // BLAKE2b-256 over the 36 bytes before it.
    const body = text.slice(EXPORT_PREFIX.length);
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    const bytes: number[] = [];
    let bits = 0;
    let value = 0;
    for (const ch of body) {
      value = (value << 5) | alphabet.indexOf(ch);
      bits += 5;
      if (bits >= 8) {
        bytes.push((value >>> (bits - 8)) & 0xff);
        bits -= 8;
      }
      value &= (1 << bits) - 1;
    }
    expect(bytes).toHaveLength(40);
    expect(bytes.slice(32, 36)).toEqual([0, 0, 0, 0]);
    expect(bytesToHex(Uint8Array.from(bytes.slice(36)))).toBe(CHECKSUM_0);
    expect(bytesToHex(blake2b(Uint8Array.from(bytes.slice(0, 36)), { dkLen: 32 }).slice(0, 4))).toBe(
      CHECKSUM_0,
    );
  });

  it('accepts a lowercase body and surrounding whitespace', () => {
    const text = exportIdentity(VECTOR_SEED, 7, 3);
    expect(importIdentity(`  ${text.toLowerCase()}\n`).nextI).toBe(7);
    expect(importIdentity(`\t${text}\n`).nextI).toBe(7);
    expect(importIdentity(text.toLowerCase()).generation).toBe(3);
  });

  it('imports the old zifir1 prefix but never writes it', () => {
    expect(LEGACY_EXPORT_PREFIX).toBe('zifir1');
    const legacy = `${LEGACY_EXPORT_PREFIX}${GOLDEN_NEXT_7.slice(EXPORT_PREFIX.length)}`;
    expect(legacy).toHaveLength(70);

    const restored = importIdentity(legacy);
    expect(bytesToHex(restored.seed)).toBe(bytesToHex(VECTOR_SEED));
    expect(restored.nextI).toBe(7);
    expect(restored.generation).toBe(3);
    expect(restored.warnings).toHaveLength(1);
    expect(restored.warnings[0]!.code).toBe('legacy-prefix');
    expect(restored.warnings[0]!.message).toMatch(/zifir1/);

    // Exporting the same identity always comes back with the new prefix.
    expect(exportIdentity(restored.seed, restored.nextI, restored.generation)).toBe(
      GOLDEN_NEXT_7,
    );
    expect(exportIdentity(restored.seed, restored.nextI, restored.generation)).not.toMatch(
      /^zifir1/,
    );
  });

  it('rejects a broken checksum', () => {
    const text = exportIdentity(VECTOR_SEED, 7, 3);
    expect(() => importIdentity(flipChar(text, 70))).toThrow(IdentityImportError);
    expect(() => importIdentity(flipChar(text, 69))).toThrow(IdentityImportError);
  });

  it('rejects a corrupted seed', () => {
    const text = exportIdentity(VECTOR_SEED, 7, 3);
    expect(() => importIdentity(flipChar(text, 20))).toThrow(IdentityImportError);
  });

  it('rejects malformed input', () => {
    const text = exportIdentity(VECTOR_SEED, 7, 3);
    const body = text.slice(EXPORT_PREFIX.length);
    expect(() => importIdentity('')).toThrow(IdentityImportError);
    expect(() => importIdentity('   \n ')).toThrow(IdentityImportError);
    expect(() => importIdentity(text.slice(0, -1))).toThrow(IdentityImportError);
    expect(() => importIdentity(`${text}a`)).toThrow(IdentityImportError);
    expect(() => importIdentity(`x${text}`)).toThrow(IdentityImportError);
    expect(() => importIdentity(`zifir2${body}`)).toThrow(IdentityImportError);
    expect(() => importIdentity(`${text.slice(0, 10)}1${text.slice(11)}`)).toThrow(IdentityImportError);
    // Case is not significant, like `decode_line/1`.
    expect(importIdentity(`ZIFIRI1${body}`).nextI).toBe(7);
    expect(importIdentity(`Zifiri1${body}`).generation).toBe(3);
    expect(() => importIdentity(`${text.slice(0, 10)} ${text.slice(10)}`)).toThrow(IdentityImportError);
  });

  it('rejects invalid next_i and generation values on export', () => {
    expect(() => exportIdentity(VECTOR_SEED, -1)).toThrow(RangeError);
    expect(() => exportIdentity(VECTOR_SEED, 1.5)).toThrow(RangeError);
    expect(() => exportIdentity(VECTOR_SEED, MAX_NEXT_I + 1)).toThrow(RangeError);
    expect(() => exportIdentity(VECTOR_SEED, 2 ** 32)).toThrow(RangeError);
    expect(() => exportIdentity(new Uint8Array(31), 0)).toThrow(TypeError);
    expect(() => exportIdentity(VECTOR_SEED, 0, -1)).toThrow(RangeError);
    expect(() => exportIdentity(VECTOR_SEED, 0, MAX_GENERATION + 1)).toThrow(RangeError);
    expect(() => exportIdentity(VECTOR_SEED, 0, 1.5)).toThrow(RangeError);
  });
});

describe('mailbox id', () => {
  it('is derived from the seed and the generation, not chosen', () => {
    expect(MAILBOX_ID_LENGTH).toBe(16);
    expect(bytesToHex(deriveMailboxId(VECTOR_SEED, 0))).toBe(MAILBOX_0);
    expect(bytesToHex(deriveMailboxId(VECTOR_SEED, 3))).toBe(MAILBOX_3);
    expect(bytesToHex(deriveMailboxId(VECTOR_SEED, 5))).toBe(MAILBOX_5);

    // Same inputs, same address — on any device, with nothing stored.
    expect(bytesToHex(deriveMailboxId(VECTOR_SEED, 3))).toBe(
      bytesToHex(deriveMailboxId(VECTOR_SEED, 3)),
    );
  });

  it('is 16 bytes, never all zeroes, and not a slice of the seed', () => {
    const id = deriveMailboxId(VECTOR_SEED, 0);
    expect(id).toHaveLength(MAILBOX_ID_LENGTH);
    expect(id.some((byte) => byte !== 0)).toBe(true);
    expect(bytesToHex(id)).not.toBe(bytesToHex(VECTOR_SEED.slice(0, 16)));
  });

  it('changes with the generation and with the seed', () => {
    const seen = new Set(
      Array.from({ length: 256 }, (_, generation) => bytesToHex(deriveMailboxId(VECTOR_SEED, generation))),
    );
    expect(seen.size).toBe(256);
    expect(bytesToHex(deriveMailboxId(new Uint8Array(32).fill(7), 0))).not.toBe(MAILBOX_0);
  });

  it('rejects a generation outside one byte and a bad seed', () => {
    expect(() => deriveMailboxId(VECTOR_SEED, -1)).toThrow(RangeError);
    expect(() => deriveMailboxId(VECTOR_SEED, 256)).toThrow(RangeError);
    expect(() => deriveMailboxId(VECTOR_SEED, 1.5)).toThrow(RangeError);
    expect(() => deriveMailboxId(new Uint8Array(31), 0)).toThrow(TypeError);
  });

  it('is reachable from an imported line without carrying the id', () => {
    const restored = importIdentity(GOLDEN_NEXT_7);
    expect(bytesToHex(deriveMailboxId(restored.seed, restored.generation))).toBe(MAILBOX_3);
    // Nothing on the line is the mailbox id: 71 characters carry seed,
    // generation, index and checksum only.
    expect(GOLDEN_NEXT_7).not.toContain(MAILBOX_3);
  });
});
