/**
 * Fixed-size padding (plan §4.1).
 * Wire body: u32be(payload length) || payload || zero padding, total = bucket size.
 */
export const PAD_BUCKETS = [256, 1024, 4096, 16384] as const;
export type PadBucket = (typeof PAD_BUCKETS)[number];

const LENGTH_PREFIX = 4;
export const MAX_PAYLOAD = 16384 - LENGTH_PREFIX;

export class PadError extends Error {
  override name = 'PadError';
}

/** Smallest bucket that fits the payload (or the explicit bucket, if larger). */
export function selectBucket(payloadLength: number, bucket?: PadBucket): PadBucket {
  if (!Number.isInteger(payloadLength) || payloadLength < 0 || payloadLength > MAX_PAYLOAD) {
    throw new PadError(`payload must be 0..${MAX_PAYLOAD} bytes`);
  }
  const needed = payloadLength + LENGTH_PREFIX;
  const selected = bucket ?? PAD_BUCKETS.find((size) => size >= needed);
  if (selected === undefined) throw new PadError('payload exceeds the largest bucket');
  if (!PAD_BUCKETS.includes(selected)) throw new PadError(`unknown bucket: ${selected}`);
  if (selected < needed) throw new PadError(`payload does not fit bucket ${selected}`);
  return selected;
}

export function encode(payload: Uint8Array, bucket?: PadBucket): Uint8Array {
  if (!(payload instanceof Uint8Array)) throw new PadError('payload must be a Uint8Array');
  const size = selectBucket(payload.length, bucket);
  const body = new Uint8Array(size);
  new DataView(body.buffer).setUint32(0, payload.length, false);
  body.set(payload, LENGTH_PREFIX);
  return body;
}

export function decode(body: Uint8Array): Uint8Array {
  if (!(body instanceof Uint8Array)) throw new PadError('body must be a Uint8Array');
  if (!(PAD_BUCKETS as readonly number[]).includes(body.length)) {
    throw new PadError(`body length ${body.length} is not a bucket size`);
  }
  const length = new DataView(body.buffer, body.byteOffset, LENGTH_PREFIX).getUint32(0, false);
  if (length > body.length - LENGTH_PREFIX) {
    throw new PadError('length prefix exceeds bucket');
  }
  for (let i = LENGTH_PREFIX + length; i < body.length; i++) {
    if (body[i] !== 0) throw new PadError('non-zero padding');
  }
  return body.slice(LENGTH_PREFIX, LENGTH_PREFIX + length);
}
