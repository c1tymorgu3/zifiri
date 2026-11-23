import { describe, expect, it } from 'vitest';
import { x25519 } from '@noble/curves/ed25519.js';
import { bytesToHex, hexToBytes, utf8ToBytes } from '@noble/hashes/utils.js';
import {
  ENVELOPE_BUCKET,
  ENVELOPE_OVERHEAD,
  EPH_PK_LENGTH,
  MAX_PLAINTEXT,
  NONCE_LENGTH,
  OpenError,
  PAD_BUCKETS,
  RECIPIENT_TAG_LENGTH,
  SEAL_OVERHEAD,
  SealError,
  buildEnvelope,
  open,
  padTo,
  recipientKeyFromBase64,
  recipientKeyToBase64,
  recipientTag,
  seal,
  splitEnvelope,
  unpad,
} from '../src/seal';

function keypair(): { sk: Uint8Array; pk: Uint8Array } {
  const sk = x25519.utils.randomSecretKey();
  return { sk, pk: x25519.getPublicKey(sk) };
}

const TAG = Uint8Array.from({ length: RECIPIENT_TAG_LENGTH }, (_, i) => 0x10 + i);

/** Flips one bit in place (noUncheckedIndexedAccess forbids `bytes[i] ^= x`). */
function flip(bytes: Uint8Array, index: number, mask: number): void {
  bytes[index] = (bytes[index] ?? 0) ^ mask;
}

// Vector produced by an independent implementation: node:crypto
// createCipheriv('aes-256-gcm') over key = HKDF-SHA256(X25519(ephSk, recipientPk),
// info = "zifiri/dm/v1"), laid out as eph_pk || nonce || ct || tag.
const KAT_RECIPIENT_SK = '0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20';
const KAT_RECIPIENT_PK = '07a37cbc142093c8b755dc1b10e86cb426374ad16aa853ed0bdfc0b2b86d1c7c';
const KAT_SEALED =
  '4d27bcee3135c4944b28d27dd809b07be10c35160d20131caa7e85575498d07c' +
  'a0a1a2a3a4a5a6a7a8a9aaab' +
  '710ea6f2a7d0a64efdf03a143f353fb3da1beaee32f02f8d0973b8c14525f323f3b33c145f0ab5f413ed116e4a440f08d4';
const KAT_PLAINTEXT = 'zifiri sealed sender v1 — hello';

describe('seal / open roundtrip', () => {
  it('round-trips a short message', async () => {
    const { sk, pk } = keypair();
    const message = utf8ToBytes('hello');

    const sealed = await seal(pk, message);

    expect(bytesToHex(await open(sk, sealed))).toBe(bytesToHex(message));
  });

  it('round-trips an empty message', async () => {
    const { sk, pk } = keypair();

    const sealed = await seal(pk, new Uint8Array(0));

    expect(sealed.length).toBe(SEAL_OVERHEAD);
    expect((await open(sk, sealed)).length).toBe(0);
  });

  it('round-trips a 3.9 KB message and still fits one 4 KB bucket', async () => {
    const { sk, pk } = keypair();
    const message = Uint8Array.from({ length: 3900 }, (_, i) => (i * 31 + 7) & 0xff);

    const sealed = await seal(pk, message);
    const padded = padTo(buildEnvelope(TAG, sealed));

    expect(sealed.length).toBe(SEAL_OVERHEAD + 3900);
    expect(padded.length).toBe(ENVELOPE_BUCKET);
    expect(bytesToHex(await open(sk, unpad(padded).subarray(RECIPIENT_TAG_LENGTH)))).toBe(bytesToHex(message));
  });

  it('accepts exactly MAX_PLAINTEXT and rejects one byte more', async () => {
    const { pk } = keypair();

    const sealed = await seal(pk, new Uint8Array(MAX_PLAINTEXT));
    expect(padTo(buildEnvelope(TAG, sealed)).length).toBe(ENVELOPE_BUCKET);

    await expect(seal(pk, new Uint8Array(MAX_PLAINTEXT + 1))).rejects.toThrow(SealError);
  });

  it('rejects a recipient key that is not 32 bytes', async () => {
    await expect(seal(new Uint8Array(31), new Uint8Array(1))).rejects.toThrow(SealError);
  });
});

describe('envelope layout', () => {
  it('lays out eph_pk(32) | nonce(12) | ct | tag(16)', async () => {
    const { sk, pk } = keypair();
    const message = utf8ToBytes('layout');

    const sealed = await seal(pk, message);
    const ephPk = sealed.subarray(0, EPH_PK_LENGTH);
    const nonce = sealed.subarray(EPH_PK_LENGTH, EPH_PK_LENGTH + NONCE_LENGTH);
    const ct = sealed.subarray(EPH_PK_LENGTH + NONCE_LENGTH, sealed.length - 16);
    const tag = sealed.subarray(sealed.length - 16);

    expect(sealed.length).toBe(EPH_PK_LENGTH + NONCE_LENGTH + message.length + 16);
    expect(ephPk.length).toBe(32);
    expect(nonce.length).toBe(12);
    expect(ct.length).toBe(message.length);
    expect(tag.length).toBe(16);
    expect(bytesToHex(ephPk)).not.toBe(bytesToHex(pk));
    // The ephemeral key must be a usable X25519 point.
    const other = x25519.utils.randomSecretKey();
    expect(x25519.getSharedSecret(other, ephPk).length).toBe(32);
    // ...and the whole thing must open with the recipient key only.
    expect(bytesToHex(await open(sk, sealed))).toBe(bytesToHex(message));
  });

  it('uses a fresh ephemeral key and nonce for every message', async () => {
    const { sk, pk } = keypair();
    const message = utf8ToBytes('same plaintext, different bytes');

    const first = await seal(pk, message);
    const second = await seal(pk, message);

    const eph = (s: Uint8Array) => bytesToHex(s.subarray(0, EPH_PK_LENGTH));
    const nonce = (s: Uint8Array) => bytesToHex(s.subarray(EPH_PK_LENGTH, EPH_PK_LENGTH + NONCE_LENGTH));

    expect(eph(first)).not.toBe(eph(second));
    expect(nonce(first)).not.toBe(nonce(second));
    expect(bytesToHex(first)).not.toBe(bytesToHex(second));
    expect(bytesToHex(await open(sk, first))).toBe(bytesToHex(message));
    expect(bytesToHex(await open(sk, second))).toBe(bytesToHex(message));
  });
});

describe('open rejects without leaking plaintext', () => {
  it('rejects a different secret key', async () => {
    const { pk } = keypair();
    const stranger = keypair();

    const sealed = await seal(pk, utf8ToBytes('gizli'));

    await expect(open(stranger.sk, sealed)).rejects.toBeInstanceOf(OpenError);
  });

  it('rejects a corrupted GCM tag', async () => {
    const { sk, pk } = keypair();
    const sealed = await seal(pk, utf8ToBytes('gizli'));
    flip(sealed, sealed.length - 1, 0x01);

    await expect(open(sk, sealed)).rejects.toBeInstanceOf(OpenError);
  });

  it('rejects corrupted ciphertext', async () => {
    const { sk, pk } = keypair();
    const sealed = await seal(pk, utf8ToBytes('secret message'));
    flip(sealed, SEAL_OVERHEAD - 1, 0x80);

    await expect(open(sk, sealed)).rejects.toBeInstanceOf(OpenError);
  });

  it('rejects a swapped ephemeral key', async () => {
    const { sk, pk } = keypair();
    const sealed = await seal(pk, utf8ToBytes('gizli'));
    const other = await seal(pk, utf8ToBytes('baska'));
    sealed.set(other.subarray(0, EPH_PK_LENGTH), 0);

    await expect(open(sk, sealed)).rejects.toBeInstanceOf(OpenError);
  });

  it('rejects a tampered nonce', async () => {
    const { sk, pk } = keypair();
    const sealed = await seal(pk, utf8ToBytes('gizli'));
    flip(sealed, EPH_PK_LENGTH, 0xff);

    await expect(open(sk, sealed)).rejects.toBeInstanceOf(OpenError);
  });

  it('rejects truncated and malformed envelopes', async () => {
    const { sk, pk } = keypair();
    const sealed = await seal(pk, utf8ToBytes('gizli'));

    await expect(open(sk, sealed.subarray(0, SEAL_OVERHEAD - 1))).rejects.toBeInstanceOf(OpenError);
    await expect(open(sk, new Uint8Array(0))).rejects.toBeInstanceOf(OpenError);
    await expect(open(sk, new Uint8Array(SEAL_OVERHEAD))).rejects.toBeInstanceOf(OpenError);
  });

  it('rejects a secret key of the wrong length', async () => {
    const { pk } = keypair();
    const sealed = await seal(pk, utf8ToBytes('gizli'));

    await expect(open(new Uint8Array(16), sealed)).rejects.toBeInstanceOf(OpenError);
  });

  it('reports one generic message and never the plaintext', async () => {
    const { sk, pk } = keypair();
    const message = 'very secret text';
    const sealed = await seal(pk, utf8ToBytes(message));
    flip(sealed, sealed.length - 1, 0xff);

    const error = await open(sk, sealed).then(
      () => null,
      (reason: unknown) => reason,
    );

    expect(error).toBeInstanceOf(OpenError);
    expect((error as Error).message).not.toContain('gizli metin');
    expect((error as Error).message).toBe('sealed envelope could not be opened');
  });
});

describe('recipient tag comes from the server', () => {
  it('carries the raw public key and returns the server tag untouched', async () => {
    const { pk } = keypair();
    const seen: Uint8Array[] = [];

    const tag = await recipientTag(pk, async (recipientPk) => {
      seen.push(recipientPk);
      return TAG;
    });

    expect(seen).toHaveLength(1);
    expect(bytesToHex(seen[0]!)).toBe(bytesToHex(pk));
    expect(seen[0]).not.toBe(pk);
    expect(bytesToHex(tag)).toBe(bytesToHex(TAG));
    expect(tag).not.toBe(TAG);
  });

  it('rejects a tag that is not 16 bytes', async () => {
    const { pk } = keypair();

    await expect(recipientTag(pk, async () => new Uint8Array(15))).rejects.toThrow(SealError);
    await expect(recipientTag(pk, async () => new Uint8Array(17))).rejects.toThrow(SealError);
  });

  it('builds and splits the wire envelope', async () => {
    const { sk, pk } = keypair();
    const message = utf8ToBytes('zarf');
    const sealed = await seal(pk, message);

    const envelope = buildEnvelope(TAG, sealed);
    const parts = splitEnvelope(envelope);

    expect(envelope.length).toBe(ENVELOPE_OVERHEAD + message.length);
    expect(bytesToHex(parts.recipientTag)).toBe(bytesToHex(TAG));
    expect(bytesToHex(await open(sk, parts.sealed))).toBe(bytesToHex(message));
    expect(() => buildEnvelope(new Uint8Array(15), sealed)).toThrow(SealError);
    expect(() => splitEnvelope(new Uint8Array(ENVELOPE_OVERHEAD - 1))).toThrow(SealError);
  });

  it('transports the public key as base64', () => {
    const { pk } = keypair();
    const encoded = recipientKeyToBase64(pk);

    expect(encoded).not.toContain('-');
    expect(encoded).not.toContain('_');
    expect(bytesToHex(recipientKeyFromBase64(encoded))).toBe(bytesToHex(pk));
    expect(() => recipientKeyFromBase64('AAAA')).toThrow(SealError);
    expect(() => recipientKeyFromBase64('not base64!!')).toThrow(SealError);
  });
});

describe('4 KB padding', () => {
  it('pads to the bucket and unpads to the same bytes', async () => {
    const { pk } = keypair();
    const sealed = await seal(pk, utf8ToBytes('kova'));
    const envelope = buildEnvelope(TAG, sealed);

    const padded = padTo(envelope);

    expect(padded.length).toBe(4096);
    expect(padded[0]).toBe(0);
    expect(padded[1]).toBe(0);
    expect(padded[2]).toBe((envelope.length >> 8) & 0xff);
    expect(padded[3]).toBe(envelope.length & 0xff);
    expect(bytesToHex(unpad(padded))).toBe(bytesToHex(envelope));
  });

  it('rejects a non-bucket length, a dirty tail, and a lying length prefix', async () => {
    const { pk } = keypair();
    const envelope = buildEnvelope(TAG, await seal(pk, utf8ToBytes('kova')));

    expect(() => unpad(envelope)).toThrow(SealError);

    const dirtyTail = padTo(envelope);
    dirtyTail[dirtyTail.length - 1] = 0x01;
    expect(() => unpad(dirtyTail)).toThrow(SealError);

    const lyingPrefix = padTo(envelope);
    lyingPrefix[0] = 0x00;
    lyingPrefix[1] = 0x00;
    lyingPrefix[2] = 0x10;
    lyingPrefix[3] = 0x00;
    expect(() => unpad(lyingPrefix)).toThrow(SealError);

    const short = new Uint8Array(4095);
    expect(() => unpad(short)).toThrow(SealError);
  });

  it('rejects an envelope that cannot fit the bucket', () => {
    const oversized = new Uint8Array(ENVELOPE_BUCKET - 3);

    expect(() => padTo(oversized)).toThrow(SealError);
    expect(PAD_BUCKETS).toContain(ENVELOPE_BUCKET);
  });
});

describe('known answer', () => {
  it('opens a vector produced by node:crypto AES-256-GCM', async () => {
    const recipientSk = hexToBytes(KAT_RECIPIENT_SK);

    expect(bytesToHex(x25519.getPublicKey(recipientSk))).toBe(KAT_RECIPIENT_PK);

    const plaintext = await open(recipientSk, hexToBytes(KAT_SEALED));

    expect(bytesToHex(plaintext)).toBe(bytesToHex(utf8ToBytes(KAT_PLAINTEXT)));
  });

  it('rejects the same vector with a one-bit tag flip', async () => {
    const sealed = hexToBytes(KAT_SEALED);
    flip(sealed, sealed.length - 1, 0x01);

    await expect(open(hexToBytes(KAT_RECIPIENT_SK), sealed)).rejects.toBeInstanceOf(OpenError);
  });
});
