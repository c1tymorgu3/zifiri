import { sha256 } from "@noble/hashes/sha2.js";

/**
 * The write gate, mirrored from `Zifiri.Pow` on the server.
 *
 * There is no per-IP limiter anywhere in zifiri, so this is the only thing
 * between a script and the queue. Difficulty is leading zero bits of
 * SHA-256(payloadHash || u64be(nonce)); the server picks the number and
 * rejects anything below it, so a client that skips this simply cannot write.
 */

export function leadingZeroBits(bytes: Uint8Array): number {
  let bits = 0;
  for (const byte of bytes) {
    if (byte === 0) {
      bits += 8;
      continue;
    }
    bits += Math.clz32(byte) - 24;
    return bits;
  }
  return bits;
}

function nonceBytes(nonce: number): Uint8Array {
  const out = new Uint8Array(8);
  let value = BigInt(nonce);
  for (let i = 7; i >= 0; i -= 1) {
    out[i] = Number(value & 0xffn);
    value >>= 8n;
  }
  return out;
}

export function meetsDifficulty(
  payloadHash: Uint8Array,
  nonce: number,
  bits: number,
): boolean {
  const input = new Uint8Array(payloadHash.length + 8);
  input.set(payloadHash, 0);
  input.set(nonceBytes(nonce), payloadHash.length);
  return leadingZeroBits(sha256(input)) >= bits;
}

export interface SolveOptions {
  signal?: AbortSignal;
  /** Called every `chunk` attempts so the UI can show real progress. */
  onProgress?: (attempts: number) => void;
  chunk?: number;
}

/**
 * Yields to the event loop between chunks: a solved nonce must not freeze the
 * tab, and a tab that freezes for four seconds is a tab the user closes.
 */
export async function solve(
  payloadHash: Uint8Array,
  bits: number,
  options: SolveOptions = {},
): Promise<number> {
  const chunk = options.chunk ?? 2048;
  let nonce = 0;

  for (;;) {
    for (let i = 0; i < chunk; i += 1) {
      if (meetsDifficulty(payloadHash, nonce, bits)) return nonce;
      nonce += 1;
    }
    options.onProgress?.(nonce);
    if (options.signal?.aborted) throw new DOMException("aborted", "AbortError");
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
}
