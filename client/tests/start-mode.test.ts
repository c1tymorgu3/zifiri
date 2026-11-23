import { describe, expect, it } from "vitest";

// The entry point boots the whole app on import (DOM, fetch, identity), so the
// test reads the shipped source instead of executing it. What is asserted is
// exactly the line the browser gets: the mode the product opens in.
import mainSource from "../src/main.ts?raw";

describe("shipped start mode", () => {
  it("opens the product in fast mode", () => {
    const match = /const\s+START_MODE\s*:\s*Mode\s*=\s*"([a-z]+)"/.exec(mainSource);
    expect(match, "START_MODE declaration not found in client/src/main.ts").not.toBeNull();
    expect(match?.[1]).toBe("fast");
  });

  it("seeds the shell with START_MODE rather than a literal mode", () => {
    expect(mainSource).toMatch(/mode:\s*START_MODE\s*===/);
  });
});
