/**
 * Sealed sender for 1:1 messages (plan §P0-2, scope-v5 §1:1).
 *
 * Wire layout of one envelope:
 *
 *   recipient_tag(16) | eph_pk(32) | nonce(12) | ct | tag(16)   -> 4 KB bucket
 *
 * `seal()` produces everything after the recipient tag, because the client
 * cannot compute the tag (see below). `buildEnvelope()` glues the server tag
 * on, `padTo()` fixes the body at the bucket size.
 *
 * Key agreement: a fresh X25519 ephemeral key per message, ECDH against the
 * recipient's X25519 public key, then HKDF-SHA256 with `info = "zifiri/dm/v1"`
 * (empty salt, same convention as `identity.ts`) into a 32-byte AES-256-GCM
 * key. The ephemeral private key is zeroed right after the shared secret is
 * derived; the recipient never needs it.
 *
 * AES-256-GCM is the platform's WebCrypto (`crypto.subtle`), not a JS
 * implementation: the tag comparison happens inside the browser/Node and
 * `subtle.decrypt` returns *nothing* on a bad tag, so no plaintext can leak
 * through a partial result and the bundle stays on `@noble/hashes` +
 * `@noble/curves` only. `subtle` is asynchronous, so `seal()` / `open()`
 * return promises. Every failure of `open()` collapses into one generic
 * `OpenError` message so callers cannot tell "wrong key" from "bad tag".
 *
 * ## Why there is no pepper here
 *
 * The mailbox address is `HMAC-SHA256(server_pepper, recipient_pk)[0..15]` and
 * is computed by the server. The client never sees the pepper and never
 * derives the tag: a pepper shipped in the bundle is public (anyone can read
 * the JS), and with it anyone could take a public key from a listing and check
 * offline whether it owns a mailbox. Keeping the tag server-side makes that
 * offline test impossible; the trade-off is that the server sees the
 * `recipient_pk -> tag` mapping, which it needs anyway to route the envelope.
 * `recipientTag(pk, fetchTag)` therefore only *carries* the raw public key as
 * base64 (`recipientKeyToBase64`) and returns the 16 bytes the server handed
 * back. The sender's identity is not part of the envelope at all.
 */

import { x25519 } from '@noble/curves/ed25519.js';
import { hkdf } from '@noble/hashes/hkdf.js';
import { sha256 } from '@noble/hashes/sha2.js';
import { utf8ToBytes } from '@noble/hashes/utils.js';

import { decode as unpadBody, encode as padBody, PadError, PAD_BUCKETS, type PadBucket } from './pad.js';

export { PAD_BUCKETS, type PadBucket };

/** X25519 public key length, bytes. */
export const EPH_PK_LENGTH = 32;
export const KEY_LENGTH = 32;
export const NONCE_LENGTH = 12;
export const TAG_LENGTH = 16;
export const RECIPIENT_TAG_LENGTH = 16;

/** `eph_pk || nonce` — the part that precedes the ciphertext. */
export const SEALED_HEADER_LENGTH = EPH_PK_LENGTH + NONCE_LENGTH;
/** eph_pk + nonce + GCM tag. */
export const SEAL_OVERHEAD = SEALED_HEADER_LENGTH + TAG_LENGTH;
/** recipient_tag + SEAL_OVERHEAD. */
export const ENVELOPE_OVERHEAD = RECIPIENT_TAG_LENGTH + SEAL_OVERHEAD;

/** Target bucket for a 1:1 envelope (scope-v5 §1:1). */
export const ENVELOPE_BUCKET: PadBucket = 4096;
/** Length prefix written by `padTo()` (see `pad.ts`). */
export const PAD_PREFIX_LENGTH = 4;

/**
 * Largest plaintext that still fits the 4 KB bucket once the envelope is
 * assembled and padded: 4096 - 4 (length prefix) - 76 (tag + seal overhead).
 */
export const MAX_PLAINTEXT = ENVELOPE_BUCKET - PAD_PREFIX_LENGTH - ENVELOPE_OVERHEAD;

const DM_INFO = utf8ToBytes('zifiri/dm/v1');
const OPEN_FAILED = 'sealed envelope could not be opened';

export class SealError extends Error {
  override name = 'SealError';
}

/** Wrong key, bad tag, or malformed envelope. Deliberately undifferentiated. */
export class OpenError extends Error {
  override name = 'OpenError';
}

/** Server round-trip that maps a recipient public key to its mailbox tag. */
export type FetchRecipientTag = (recipientPk: Uint8Array) => Promise<Uint8Array>;

export interface Envelope {
  recipientTag: Uint8Array;
  sealed: Uint8Array;
}

/**
 * Encrypts `plaintext` to `recipientPk` (32-byte X25519 public key).
 *
 * Returns `eph_pk(32) || nonce(12) || ct || tag(16)`; `ct.length` equals
 * `plaintext.length`. Fresh ephemeral key and fresh 96-bit nonce per call, so
 * the same plaintext never produces the same bytes twice.
 */
export async function seal(recipientPk: Uint8Array, plaintext: Uint8Array): Promise<Uint8Array> {
  assertKey(recipientPk, 'recipient public key', SealError);
  if (!(plaintext instanceof Uint8Array)) throw new SealError('plaintext must be a Uint8Array');
  if (plaintext.length > MAX_PLAINTEXT) {
    throw new SealError(`plaintext must be 0..${MAX_PLAINTEXT} bytes to fit the ${ENVELOPE_BUCKET}-byte bucket`);
  }

  const ephemeralSecret = x25519.utils.randomSecretKey();
  const ephemeralPk = x25519.getPublicKey(ephemeralSecret);
  const nonce = randomBytes(NONCE_LENGTH);

  let keyBytes: Uint8Array;
  try {
    keyBytes = deriveMessageKey(ephemeralSecret, recipientPk);
  } catch {
    throw new SealError('recipient public key is not a usable X25519 point');
  } finally {
    ephemeralSecret.fill(0);
  }

  try {
    const key = await importAesKey(keyBytes, ['encrypt']);
    const ciphertext = await globalThis.crypto.subtle.encrypt(
      { name: 'AES-GCM', iv: toBuffer(nonce), tagLength: TAG_LENGTH * 8 },
      key,
      toBuffer(plaintext),
    );
    return concat(ephemeralPk, nonce, new Uint8Array(ciphertext));
  } catch (error) {
    if (error instanceof SealError) throw error;
    throw new SealError('encryption failed');
  } finally {
    keyBytes.fill(0);
  }
}

/**
 * Decrypts `sealed` with the recipient's 32-byte X25519 secret key.
 *
 * The GCM tag is verified by `crypto.subtle.decrypt` before any plaintext is
 * returned, so a wrong key, a flipped ciphertext byte, or a truncated envelope
 * all throw `OpenError` and produce no output.
 */
export async function open(secretKey: Uint8Array, sealed: Uint8Array): Promise<Uint8Array> {
  assertKey(secretKey, 'secret key', OpenError);
  if (!(sealed instanceof Uint8Array) || sealed.length < SEAL_OVERHEAD) throw new OpenError(OPEN_FAILED);

  const ephemeralPk = sealed.subarray(0, EPH_PK_LENGTH);
  const nonce = sealed.subarray(EPH_PK_LENGTH, SEALED_HEADER_LENGTH);
  const body = sealed.subarray(SEALED_HEADER_LENGTH);

  let keyBytes: Uint8Array;
  try {
    keyBytes = deriveMessageKey(secretKey, ephemeralPk);
  } catch {
    throw new OpenError(OPEN_FAILED);
  }

  try {
    const key = await importAesKey(keyBytes, ['decrypt']);
    const plaintext = await globalThis.crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: toBuffer(nonce), tagLength: TAG_LENGTH * 8 },
      key,
      toBuffer(body),
    );
    return new Uint8Array(plaintext);
  } catch {
    throw new OpenError(OPEN_FAILED);
  } finally {
    keyBytes.fill(0);
  }
}

/**
 * Asks the server for `HMAC(pepper, recipient_pk)[0..15]`.
 *
 * The client computes nothing here — it hands the raw public key to
 * `fetchTag` (which base64-encodes it for the request) and validates the shape
 * of what comes back. See the module header for why the pepper stays on the
 * server.
 */
export async function recipientTag(recipientPk: Uint8Array, fetchTag: FetchRecipientTag): Promise<Uint8Array> {
  assertKey(recipientPk, 'recipient public key', SealError);
  if (typeof fetchTag !== 'function') throw new SealError('fetchTag must be a function');

  const tag = await fetchTag(recipientPk.slice());
  if (!(tag instanceof Uint8Array) || tag.length !== RECIPIENT_TAG_LENGTH) {
    throw new SealError(`recipient tag must be ${RECIPIENT_TAG_LENGTH} bytes`);
  }
  return tag.slice();
}

/** `recipient_tag || sealed` — the wire envelope the server stores. */
export function buildEnvelope(tag: Uint8Array, sealed: Uint8Array): Uint8Array {
  if (!(tag instanceof Uint8Array) || tag.length !== RECIPIENT_TAG_LENGTH) {
    throw new SealError(`recipient tag must be ${RECIPIENT_TAG_LENGTH} bytes`);
  }
  if (!(sealed instanceof Uint8Array) || sealed.length < SEAL_OVERHEAD) {
    throw new SealError(`sealed body must be at least ${SEAL_OVERHEAD} bytes`);
  }
  return concat(tag, sealed);
}

/** Inverse of `buildEnvelope()`. Does not authenticate the tag. */
export function splitEnvelope(envelope: Uint8Array): Envelope {
  if (!(envelope instanceof Uint8Array) || envelope.length < ENVELOPE_OVERHEAD) {
    throw new SealError(`envelope must be at least ${ENVELOPE_OVERHEAD} bytes`);
  }
  return {
    recipientTag: envelope.slice(0, RECIPIENT_TAG_LENGTH),
    sealed: envelope.slice(RECIPIENT_TAG_LENGTH),
  };
}

/**
 * `u32be(envelope length) || envelope || zero fill`, total = bucket size.
 *
 * Same shape as `pad.ts` so one decoder covers both. The 4-byte prefix is what
 * makes `unpad()` unambiguous; it also means the body reveals the envelope
 * length to the byte. Callers that must hide message length pad the plaintext
 * before `seal()` (e.g. with `pad.ts`) so every envelope is the same size.
 */
export function padTo(envelope: Uint8Array, bucket: PadBucket = ENVELOPE_BUCKET): Uint8Array {
  if (!(envelope instanceof Uint8Array)) throw new SealError('envelope must be a Uint8Array');
  try {
    return padBody(envelope, bucket);
  } catch (error) {
    throw asSealError(error);
  }
}

/**
 * Validates the bucket size, the length prefix, and the all-zero tail, then
 * returns a copy of the envelope. Never returns trailing padding.
 */
export function unpad(padded: Uint8Array): Uint8Array {
  if (!(padded instanceof Uint8Array)) throw new SealError('padded body must be a Uint8Array');
  try {
    return unpadBody(padded);
  } catch (error) {
    throw asSealError(error);
  }
}

/** Standard base64 (not base64url) — the form the mailbox endpoint takes. */
export function recipientKeyToBase64(recipientPk: Uint8Array): string {
  assertKey(recipientPk, 'recipient public key', SealError);
  let binary = '';
  for (const byte of recipientPk) binary += String.fromCharCode(byte);
  return btoa(binary);
}

/** Decodes a base64 recipient key; rejects anything that is not 32 bytes. */
export function recipientKeyFromBase64(value: string): Uint8Array {
  if (typeof value !== 'string' || value.length === 0) throw new SealError('recipient key must be a base64 string');
  let binary: string;
  try {
    binary = atob(value);
  } catch {
    throw new SealError('recipient key is not valid base64');
  }
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  assertKey(out, 'recipient key', SealError);
  return out;
}

/** ECDH -> HKDF-SHA256("zifiri/dm/v1") -> 32-byte AES-256-GCM key. */
function deriveMessageKey(secretKey: Uint8Array, peerPk: Uint8Array): Uint8Array {
  const shared = x25519.getSharedSecret(secretKey, peerPk);
  try {
    if (isAllZero(shared)) throw new Error('degenerate shared secret');
    return hkdf(sha256, shared, undefined, DM_INFO, KEY_LENGTH);
  } finally {
    shared.fill(0);
  }
}

async function importAesKey(raw: Uint8Array, usages: KeyUsage[]): Promise<CryptoKey> {
  return globalThis.crypto.subtle.importKey('raw', toBuffer(raw), { name: 'AES-GCM' }, false, usages);
}

/**
 * `crypto.subtle` only takes `ArrayBuffer`-backed views; noble hands back
 * `Uint8Array<ArrayBufferLike>`. Copying a 4 KB body is free next to AES-GCM.
 */
function toBuffer(bytes: Uint8Array): Uint8Array<ArrayBuffer> {
  const copy = new Uint8Array(bytes.length);
  copy.set(bytes);
  return copy;
}

function randomBytes(length: number): Uint8Array<ArrayBuffer> {
  const api = globalThis.crypto;
  if (!api || typeof api.getRandomValues !== 'function') {
    throw new SealError('crypto.getRandomValues is not available');
  }
  const out = new Uint8Array(length);
  api.getRandomValues(out);
  return out;
}

function assertKey(key: Uint8Array, what: string, kind: typeof SealError | typeof OpenError): void {
  if (!(key instanceof Uint8Array) || key.length !== KEY_LENGTH) {
    throw new kind(`${what} must be a ${KEY_LENGTH}-byte Uint8Array`);
  }
}

function isAllZero(bytes: Uint8Array): boolean {
  let acc = 0;
  for (const byte of bytes) acc |= byte;
  return acc === 0;
}

function asSealError(error: unknown): SealError {
  if (error instanceof SealError) return error;
  const message = error instanceof PadError || error instanceof Error ? error.message : String(error);
  return new SealError(message);
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
