import { describe, expect, it } from 'vitest';
import { decode, encode, MAX_PAYLOAD, PAD_BUCKETS, PadError, selectBucket } from '../src/pad';

function payload(length: number): Uint8Array {
  return Uint8Array.from({ length }, (_, i) => (i * 31 + 7) & 0xff);
}

describe('pad buckets', () => {
  it('are the fixed sizes from the plan', () => {
    expect(PAD_BUCKETS).toEqual([256, 1024, 4096, 16384]);
  });

  it('selects the smallest fitting bucket', () => {
    expect(selectBucket(0)).toBe(256);
    expect(selectBucket(252)).toBe(256);
    expect(selectBucket(253)).toBe(1024);
    expect(selectBucket(1020)).toBe(1024);
    expect(selectBucket(1021)).toBe(4096);
    expect(selectBucket(4092)).toBe(4096);
    expect(selectBucket(4093)).toBe(16384);
    expect(selectBucket(MAX_PAYLOAD)).toBe(16384);
  });

  it('honours an explicit larger bucket and rejects a smaller one', () => {
    expect(encode(payload(10), 4096)).toHaveLength(4096);
    expect(() => encode(payload(10), 256)).not.toThrow();
    expect(() => encode(payload(300), 256)).toThrow(PadError);
    expect(() => encode(payload(10), 300 as never)).toThrow(PadError);
  });

  it('rejects oversized payloads', () => {
    expect(() => encode(payload(MAX_PAYLOAD + 1))).toThrow(PadError);
    expect(() => encode(payload(20000))).toThrow(PadError);
    expect(() => selectBucket(-1)).toThrow(PadError);
  });

  it('round-trips every bucket at its edges', () => {
    for (const bucket of PAD_BUCKETS) {
      for (const size of [0, 1, 17, bucket - 5, bucket - 4]) {
        if (size < 0) continue;
        const input = payload(size);
        const body = encode(input);
        expect(body).toHaveLength(selectBucket(size));
        expect(decode(body)).toEqual(input);
      }
    }
  });

  it('round-trips a payload that ends in zero bytes', () => {
    const input = Uint8Array.from([1, 2, 3, 0, 0, 0]);
    expect(decode(encode(input))).toEqual(input);
  });

  it('writes a big-endian length prefix and zero padding', () => {
    const input = payload(5);
    const body = encode(input);
    expect(Array.from(body.slice(0, 4))).toEqual([0, 0, 0, 5]);
    expect(body.slice(4, 9)).toEqual(input);
    expect(body.slice(9).every((byte) => byte === 0)).toBe(true);
  });

  it('returns a copy, not a view into the envelope', () => {
    const body = encode(payload(4));
    const out = decode(body);
    out[0] = 0xff;
    expect(body[4]).not.toBe(0xff);
  });
});

describe('pad decode validation', () => {
  it('rejects non-bucket lengths', () => {
    for (const length of [0, 4, 255, 300, 1023, 5000]) {
      expect(() => decode(new Uint8Array(length))).toThrow(PadError);
    }
  });

  it('rejects a length prefix larger than the bucket', () => {
    const body = encode(payload(10));
    new DataView(body.buffer).setUint32(0, 253, false);
    expect(() => decode(body)).toThrow(PadError);

    new DataView(body.buffer).setUint32(0, 0xffffffff, false);
    expect(() => decode(body)).toThrow(PadError);
  });

  it('rejects non-zero padding', () => {
    const body = encode(payload(10));
    body[body.length - 1] = 1;
    expect(() => decode(body)).toThrow(PadError);
    body[body.length - 1] = 0;
    body[20] = 9;
    expect(() => decode(body)).toThrow(PadError);
  });

  it('rejects non-byte input', () => {
    expect(() => decode('body' as unknown as Uint8Array)).toThrow(PadError);
    expect(() => encode('payload' as unknown as Uint8Array)).toThrow(PadError);
  });
});
