import { ed25519 } from '@noble/curves/ed25519.js';
import { blake2b } from '@noble/hashes/blake2.js';
import { hkdf } from '@noble/hashes/hkdf.js';
import { sha256 } from '@noble/hashes/sha2.js';
import { bytesToHex, utf8ToBytes } from '@noble/hashes/utils.js';

/** 32-byte secret; never leaves the device. */
export const SEED_LENGTH = 32;

/**
 * 16-byte mailbox address, derived from the seed and the generation.
 *
 * Nothing is stored and nothing is chosen at random: the same seed and the
 * same generation give the same mailbox on every device, and the server —
 * which never sees the seed — sees a label that looks random. It is the same
 * 16 bytes the server stores in `mailbox_envelopes.mailbox_id`.
 */
export const MAILBOX_ID_LENGTH = 16;

/** One byte on the line: 0–255 mailbox generations. */
export const MAX_GENERATION = 0xff;

/** Three bytes on the line: the highest ownership index it can carry. */
export const MAX_NEXT_I = 0xffffff;

/** What every exported line starts with: the product name plus a version digit. */
export const EXPORT_PREFIX = 'zifiri1';

/**
 * The prefix this client shipped with before the format settled. Accepted on
 * import so a line copied out of an older build still loads; never written.
 */
export const LEGACY_EXPORT_PREFIX = 'zifir1';

/** 40 bytes of base32, no padding. */
export const BODY_LENGTH = 64;

/** `zifiri1` (7) + 64 base32 characters. Fixed by the design, not by taste. */
export const LINE_LENGTH = EXPORT_PREFIX.length + BODY_LENGTH;

const OWN_INFO = utf8ToBytes('zifiri/own/v1');
const ID_INFO = utf8ToBytes('zifiri/id/v1');
const MAILBOX_INFO = 'zifiri/mailbox/v1/';

const EXPORT_CHECKSUM_LENGTH = 4;
const EXPORT_PAYLOAD_LENGTH = SEED_LENGTH + 1 + 3;
const BASE32_ALPHABET = 'abcdefghijklmnopqrstuvwxyz234567';

export interface Identity {
  seed: Uint8Array;
  /** Next ownership index; indexes below it may already be used. */
  nextI: number;
  /**
   * Mailbox generation, 0–255. Bumping it re-derives `mailbox_id`, which is
   * the only way to move to a fresh address without a new seed. Absent means
   * 0, the first mailbox — an identity created before the field existed.
   */
  generation?: number;
}

/** Why an imported identity is not the shape this build writes. */
export interface IdentityWarning {
  code: 'legacy-prefix';
  message: string;
}

/** An identity as decoded from an export, plus anything worth telling the user. */
export interface ImportedIdentity extends Identity {
  /** Always present: every line carries one byte of it. */
  generation: number;
  warnings: IdentityWarning[];
}

export interface IdentityKeyPair {
  /** 32-byte Ed25519 seed. */
  secretKey: Uint8Array;
  publicKey: Uint8Array;
}

export class IdentityImportError extends Error {
  override name = 'IdentityImportError';
}

/** Fresh seed from the platform CSPRNG. */
export function generateSeed(): Uint8Array {
  const cryptoApi = globalThis.crypto;
  if (!cryptoApi || typeof cryptoApi.getRandomValues !== 'function') {
    throw new Error('crypto.getRandomValues is not available');
  }
  const seed = new Uint8Array(SEED_LENGTH);
  cryptoApi.getRandomValues(seed);
  return seed;
}

export function createIdentity(): Identity {
  return { seed: generateSeed(), nextI: 0, generation: 0 };
}

/**
 * HKDF-SHA256(seed, info = "zifiri/mailbox/v1/" || decimal generation), 16 B.
 *
 * Identical to `Zifiri.Identity.derive_mailbox_id/2` on the server, so both
 * sides agree on where a message is delivered without the seed ever leaving
 * the device. The generation goes in as its decimal text (not as a byte)
 * because the server spells it that way and both must hash the same bytes.
 */
export function deriveMailboxId(seed: Uint8Array, generation = 0): Uint8Array {
  assertSeed(seed);
  assertGeneration(generation);
  const info = utf8ToBytes(`${MAILBOX_INFO}${generation}`);
  return hkdf(sha256, seed, undefined, info, MAILBOX_ID_LENGTH);
}

/** HKDF-SHA256(seed, info = "zifiri/own/v1" || u32be(i)), 32 bytes. */
export function deriveOwnToken(seed: Uint8Array, index: number): Uint8Array {
  assertSeed(seed);
  const info = concat(OWN_INFO, u32be(index));
  return hkdf(sha256, seed, undefined, info, 32);
}

/** Bulk derivation for the "disappear" sweep (plan §3.3). */
export function deriveOwnTokens(seed: Uint8Array, start: number, count: number): Uint8Array[] {
  assertSeed(seed);
  if (!Number.isInteger(count) || count < 0 || count > 4096) {
    throw new RangeError('count must be an integer in [0, 4096]');
  }
  u32be(start);
  if (count > 0 && start + count - 1 > 0xffffffff) {
    throw new RangeError('index range exceeds u32');
  }
  const tokens: Uint8Array[] = [];
  for (let i = 0; i < count; i++) tokens.push(deriveOwnToken(seed, start + i));
  return tokens;
}

/** Ed25519 key pair derived from the seed with its own domain separator. */
export function deriveIdentityKeys(seed: Uint8Array): IdentityKeyPair {
  assertSeed(seed);
  const secretKey = hkdf(sha256, seed, undefined, ID_INFO, 32);
  return { secretKey, publicKey: ed25519.getPublicKey(secretKey) };
}

/**
 * Export format, 71 characters:
 *
 *   "zifiri1" || base32( seed(32) || generation(1) || u24be(next_i)(3) || checksum(4) )
 *   checksum = BLAKE2b-256(seed || generation || u24be(next_i))[0..4]
 *
 * Byte-for-byte what `Zifiri.Identity.encode_line/3` writes, so a line made
 * here imports there and back. The body is uppercase (it is meant to be read
 * aloud and retyped); the prefix stays lowercase, as on the server.
 *
 * There is no version byte and no stored mailbox id: the generation byte is
 * the version, and `mailbox_id` is derived from the seed.
 */
export function exportIdentity(seed: Uint8Array, nextI: number, generation = 0): string {
  assertSeed(seed);
  assertGeneration(generation);
  const payload = concat(seed, new Uint8Array([generation]), u24be(nextI));
  const checksum = blake2b(payload, { dkLen: 32 }).slice(0, EXPORT_CHECKSUM_LENGTH);
  return EXPORT_PREFIX + base32Encode(concat(payload, checksum)).toUpperCase();
}

/**
 * Validates and decodes an exported identity. Throws IdentityImportError.
 *
 * Two prefixes are accepted: `zifiri1` and the older `zifir1`. Both must carry
 * the 40-byte body — the layout is what changed with the rename, and a line
 * from before that (41 or 57 bytes, SHA-256 checksum, a stored mailbox id) is
 * refused by the length and checksum checks rather than half-imported.
 *
 * Case is not significant anywhere on the line, like `decode_line/1`: a line
 * pasted as `ZIFIRI1...` or typed in lower case loads. Only the body is
 * written uppercase.
 */
export function importIdentity(text: string): ImportedIdentity {
  if (typeof text !== 'string') throw new IdentityImportError('identity must be a string');
  const trimmed = text.trim();
  if (trimmed.length === 0) throw new IdentityImportError('empty identity');

  const folded = trimmed.toLowerCase();
  const prefix = [EXPORT_PREFIX, LEGACY_EXPORT_PREFIX].find((candidate) =>
    folded.startsWith(candidate),
  );
  if (prefix === undefined) {
    throw new IdentityImportError(`identity must start with "${EXPORT_PREFIX}"`);
  }

  const bytes = base32Decode(trimmed.slice(prefix.length).toLowerCase());
  if (bytes.length !== EXPORT_PAYLOAD_LENGTH + EXPORT_CHECKSUM_LENGTH) {
    throw new IdentityImportError('identity has the wrong length');
  }

  const payload = bytes.slice(0, EXPORT_PAYLOAD_LENGTH);
  const checksum = bytes.slice(EXPORT_PAYLOAD_LENGTH);
  if (!equalBytes(checksum, blake2b(payload, { dkLen: 32 }).slice(0, EXPORT_CHECKSUM_LENGTH))) {
    throw new IdentityImportError('identity checksum mismatch');
  }

  const seed = payload.slice(0, SEED_LENGTH);
  const generation = payload[SEED_LENGTH]!;
  // 3-byte big-endian index; DataView has no variable-width accessor.
  const nextI =
    payload[SEED_LENGTH + 1]! * 0x10000 + payload[SEED_LENGTH + 2]! * 0x100 + payload[SEED_LENGTH + 3]!;

  const warnings: IdentityWarning[] =
    prefix === LEGACY_EXPORT_PREFIX
      ? [
          {
            code: 'legacy-prefix',
            message: `this line starts with "${LEGACY_EXPORT_PREFIX}"; it was accepted, but new exports use "${EXPORT_PREFIX}"`,
          },
        ]
      : [];

  return { seed, nextI, generation, warnings };
}

/** Hex helper for tests and diagnostics. */
export function ownTokenHex(seed: Uint8Array, index: number): string {
  return bytesToHex(deriveOwnToken(seed, index));
}

function assertSeed(seed: Uint8Array): void {
  if (!(seed instanceof Uint8Array) || seed.length !== SEED_LENGTH) {
    throw new TypeError(`seed must be a ${SEED_LENGTH}-byte Uint8Array`);
  }
}

function assertGeneration(generation: number): void {
  if (!Number.isInteger(generation) || generation < 0 || generation > MAX_GENERATION) {
    throw new RangeError(`generation must be an integer in [0, ${MAX_GENERATION}]`);
  }
}

function u24be(value: number): Uint8Array {
  if (!Number.isInteger(value) || value < 0 || value > MAX_NEXT_I) {
    throw new RangeError('index must be an integer in [0, 2^24)');
  }
  // DataView has no variable-width accessor, so write the three bytes out.
  return new Uint8Array([(value >>> 16) & 0xff, (value >>> 8) & 0xff, value & 0xff]);
}

function u32be(value: number): Uint8Array {
  if (!Number.isInteger(value) || value < 0 || value > 0xffffffff) {
    throw new RangeError('index must be an integer in [0, 2^32)');
  }
  const out = new Uint8Array(4);
  new DataView(out.buffer).setUint32(0, value, false);
  return out;
}

function concat(...parts: Uint8Array[]): Uint8Array {
  const total = parts.reduce((n, part) => n + part.length, 0);
  const out = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

function equalBytes(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i]! ^ b[i]!;
  return diff === 0;
}

function base32Encode(bytes: Uint8Array): string {
  let out = '';
  let bits = 0;
  let value = 0;
  for (const byte of bytes) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      out += BASE32_ALPHABET[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
    value &= (1 << bits) - 1;
  }
  if (bits > 0) out += BASE32_ALPHABET[(value << (5 - bits)) & 31];
  return out;
}

function base32Decode(text: string): Uint8Array {
  const out: number[] = [];
  let bits = 0;
  let value = 0;
  for (const ch of text) {
    const index = BASE32_ALPHABET.indexOf(ch);
    if (index === -1) throw new IdentityImportError(`invalid base32 character: ${ch}`);
    value = (value << 5) | index;
    bits += 5;
    if (bits >= 8) {
      out.push((value >>> (bits - 8)) & 0xff);
      bits -= 8;
    }
    value &= (1 << bits) - 1;
  }
  if (bits >= 5 || (bits > 0 && value !== 0)) {
    throw new IdentityImportError('non-canonical base32 padding');
  }
  return Uint8Array.from(out);
}
