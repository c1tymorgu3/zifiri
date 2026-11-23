import { describe, expect, it } from "vitest";
import {
  DEFAULT_MODE,
  MODE_ANONYMITY_SET,
  MODE_DELAY_MS,
  chooseMode,
  createModeSwitch,
  describeMode,
  isMode,
  type Mode,
} from "../src/ui/mode";

describe("chooseMode", () => {
  it("defaults to silent when nothing is chosen", () => {
    expect(DEFAULT_MODE).toBe("silent");
    expect(chooseMode()).toBe("silent");
    expect(chooseMode(undefined)).toBe("silent");
    expect(chooseMode(null)).toBe("silent");
  });

  it("keeps a real choice and falls back on anything else", () => {
    expect(chooseMode("fast")).toBe("fast");
    expect(chooseMode("silent")).toBe("silent");
    // A stale string from an older build is not a mode; the safe direction is slower.
    expect(chooseMode("turbo")).toBe("silent");
    expect(chooseMode(1)).toBe("silent");
    expect(chooseMode({ mode: "fast" })).toBe("silent");
    expect(isMode("fast")).toBe(true);
    expect(isMode("FAST")).toBe(false);
  });
});

describe("describeMode", () => {
  it("says the silent promise in one Turkish line", () => {
    expect(describeMode("silent")).toBe("yazma anın ~%99 gizli, 10 dakikaya kadar bekler");
    expect(describeMode("silent")).not.toContain("\n");
  });

  it("does not sell fast mode as equally private", () => {
    const fast = describeMode("fast");
    expect(fast).toBe("yazma anın ~%80 gizli, mesaj hemen gider");
    expect(fast).not.toContain("%99");
    expect(fast).not.toContain("\n");
  });

  it("keeps the delay and set numbers in step with the copy", () => {
    expect(MODE_DELAY_MS.fast).toBe(0);
    expect(MODE_DELAY_MS.silent).toBe(10 * 60 * 1000);
    expect(MODE_ANONYMITY_SET.fast).toBe(5);
    expect(MODE_ANONYMITY_SET.silent).toBe(120);
  });
});

describe("createModeSwitch", () => {
  it("starts silent and remembers a choice in memory", () => {
    const modeSwitch = createModeSwitch();
    expect(modeSwitch.current()).toBe("silent");

    const first = modeSwitch.choose("fast");
    expect(first).toEqual({ mode: "fast", firstTime: true });
    expect(modeSwitch.current()).toBe("fast");

    // Asked once, then remembered: the same choice is not a first time again.
    expect(modeSwitch.choose("fast")).toEqual({ mode: "fast", firstTime: false });

    modeSwitch.choose("silent");
    expect(modeSwitch.current()).toBe("silent");
    expect(modeSwitch.choose("fast").firstTime).toBe(false);

    modeSwitch.reset();
    expect(modeSwitch.current()).toBe("silent");
  });

  it("does not touch any storage: the choice dies with the tab", () => {
    const trap = (): never => {
      throw new Error("storage was touched");
    };
    Object.defineProperty(globalThis, "localStorage", { configurable: true, get: trap });
    Object.defineProperty(globalThis, "sessionStorage", { configurable: true, get: trap });

    try {
      const modeSwitch = createModeSwitch();
      modeSwitch.choose("fast" satisfies Mode);
      modeSwitch.choose("silent");
      expect(modeSwitch.current()).toBe("silent");
      expect(chooseMode("fast")).toBe("fast");
      expect(describeMode("fast")).toContain("hemen");
    } finally {
      Reflect.deleteProperty(globalThis, "localStorage");
      Reflect.deleteProperty(globalThis, "sessionStorage");
    }
  });
});
