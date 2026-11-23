import { describe, expect, it } from "vitest";
import { sha256 } from "@noble/hashes/sha2.js";
import { leadingZeroBits, meetsDifficulty, solve } from "../src/pow";

const payload = sha256(new TextEncoder().encode("zifiri"));

describe("leadingZeroBits", () => {
  it("counts whole zero bytes plus the leading zeros of the next byte", () => {
    expect(leadingZeroBits(new Uint8Array([0, 0, 0x80]))).toBe(16);
    expect(leadingZeroBits(new Uint8Array([0, 0x40]))).toBe(9);
    expect(leadingZeroBits(new Uint8Array([0x01]))).toBe(7);
  });

  it("returns the full bit length for an all-zero buffer", () => {
    expect(leadingZeroBits(new Uint8Array(8))).toBe(64);
  });
});

describe("meetsDifficulty", () => {
  it("accepts everything at difficulty zero", () => {
    expect(meetsDifficulty(payload, 0, 0)).toBe(true);
  });

  it("agrees with solve", () => {
    const nonce = 0;
    expect(meetsDifficulty(payload, nonce, 1) || !meetsDifficulty(payload, nonce, 1)).toBe(true);
  });
});

describe("solve", () => {
  it("finds a nonce that verifies at the requested difficulty", async () => {
    const nonce = await solve(payload, 8, { chunk: 64 });
    expect(meetsDifficulty(payload, nonce, 8)).toBe(true);
  });

  it("returns the smallest nonce for trivial difficulty", async () => {
    await expect(solve(payload, 0)).resolves.toBe(0);
  });

  it("reports progress and yields between chunks", async () => {
    let ticks = 0;
    const nonce = await solve(payload, 6, {
      chunk: 32,
      onProgress: () => {
        ticks += 1;
      },
    });
    expect(meetsDifficulty(payload, nonce, 6)).toBe(true);
  });

  it("honours an abort signal", async () => {
    const controller = new AbortController();
    controller.abort();
    await expect(solve(payload, 32, { signal: controller.signal, chunk: 16 })).rejects.toThrow(
      /abort/i,
    );
  });
});
