/**
 * The chat frame, byte for byte, as `Zifiri.Chat.Message` sees it.
 *
 * The server signs and grinds over the *padded* body but stores the raw body;
 * getting that split wrong produces a signature that verifies nowhere. This
 * module is deliberately small and pure so the frame can be tested without a
 * network or a browser.
 */
import { ed25519 } from "@noble/curves/ed25519.js";
import { sha256 } from "@noble/hashes/sha2.js";

import { deriveIdentityKeys } from "./identity";

const encoder = new TextEncoder();

/** Domain separators, copied from the server's `@domain` attributes. */
export const CHAT_DOMAIN = encoder.encode("zifiri/chat/v1");
export const CHAT_POW_DOMAIN = encoder.encode("zifiri/chat/pow/v1");

/** `@pow_bits` on the room write path. */
export const CHAT_POW_BITS = 12;

function u16be(value: number): Uint8Array {
  return new Uint8Array([(value >>> 8) & 0xff, value & 0xff]);
}

function u64be(value: number): Uint8Array {
  const out = new Uint8Array(8);
  let rest = BigInt(value);
  for (let i = 7; i >= 0; i -= 1) {
    out[i] = Number(rest & 0xffn);
    rest >>= 8n;
  }
  return out;
}

function concat(...parts: readonly Uint8Array[]): Uint8Array {
  const total = parts.reduce((sum, part) => sum + part.length, 0);
  const out = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

/**
 * `domain || u16(len(room)) || room || u16(len(epoch)) || epoch || u64(ctr) || padded`.
 *
 * The epoch is the base64 string the server returned, used as UTF-8, not the
 * decoded bytes: that is the value the server puts in its own signing input.
 */
export function signingInput(
  room: string,
  epoch: string,
  ctr: number,
  padded: Uint8Array,
): Uint8Array {
  if (!Number.isSafeInteger(ctr) || ctr < 0) {
    throw new RangeError("ctr must be a non-negative safe integer");
  }
  const roomBytes = encoder.encode(room);
  const epochBytes = encoder.encode(epoch);
  if (roomBytes.length > 0xffff || epochBytes.length > 0xffff) {
    throw new RangeError("room or epoch is too long");
  }
  return concat(
    CHAT_DOMAIN,
    u16be(roomBytes.length),
    roomBytes,
    u16be(epochBytes.length),
    epochBytes,
    u64be(ctr),
    padded,
  );
}

/** What the client grinds: SHA-256(`zifiri/chat/pow/v1` || signing_input). */
export function powDigest(input: Uint8Array): Uint8Array {
  return sha256(concat(CHAT_POW_DOMAIN, input));
}

export interface FrameRequest {
  readonly seed: Uint8Array;
  readonly room: string;
  readonly epoch: string;
  readonly ctr: number;
  /** The raw, unpadded body the server will pad itself. */
  readonly body: Uint8Array;
  /** The padded form of `body`, for the signature. */
  readonly padded: Uint8Array;
}

export interface ChatFrame {
  /** Raw body, as sent in JSON. */
  readonly body: Uint8Array;
  readonly pubkey: Uint8Array;
  readonly sig: Uint8Array;
}

/** Signs the padded body; the nonce is not part of the signature. */
export function buildChatFrame(request: FrameRequest): ChatFrame {
  const keys = deriveIdentityKeys(request.seed);
  const input = signingInput(request.room, request.epoch, request.ctr, request.padded);
  const sig = ed25519.sign(input, keys.secretKey);
  return { body: request.body, pubkey: keys.publicKey, sig };
}

/** URL-safe, unpadded base64, the form chat keys travel in. */
export function fromB64Url(value: string): Uint8Array {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/");
  const binary = atob(padded + "=".repeat((4 - (padded.length % 4)) % 4));
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) out[i] = binary.charCodeAt(i);
  return out;
}
