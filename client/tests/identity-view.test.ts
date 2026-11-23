import { describe, expect, it } from "vitest";
import {
  createIdentityView,
  FINGERPRINT_LENGTH,
  LOST_WARNING,
  matchesVanishPhrase,
  shortFingerprint,
  VANISH_PHRASE,
} from "../src/ui/identity-view";
import { exportIdentity, importIdentity } from "../src/identity";

const SEED = Uint8Array.from({ length: 32 }, (_, i) => i + 1);
const OTHER = Uint8Array.from({ length: 32 }, (_, i) => 255 - i);
const LINE = exportIdentity(SEED, 7);

// ---------------------------------------------------------------------------
// Fake DOM, same shape as the other view tests.
// ---------------------------------------------------------------------------

type Handler = (event: { preventDefault(): void }) => void;

class FakeEl {
  className = "";
  textContent = "";
  children: (FakeEl | string)[] = [];
  dataset: Record<string, string> = {};
  attrs: Record<string, string> = {};
  listeners: Record<string, Handler[]> = {};
  value = "";
  checked = false;
  disabled = false;
  hidden = false;
  type = "";

  constructor(
    readonly tagName: string,
    readonly ownerDocument: FakeDoc,
  ) {}

  append(...nodes: (FakeEl | string)[]): void {
    this.children.push(...nodes);
  }

  replaceChildren(...nodes: (FakeEl | string)[]): void {
    this.children = nodes;
  }

  setAttribute(name: string, value: string): void {
    this.attrs[name] = value;
  }

  getAttribute(name: string): string | null {
    return this.attrs[name] ?? null;
  }

  addEventListener(type: string, handler: Handler): void {
    const list = this.listeners[type] ?? [];
    list.push(handler);
    this.listeners[type] = list;
  }

  fire(type: string): void {
    let prevented = false;
    for (const handler of this.listeners[type] ?? []) {
      handler({
        preventDefault() {
          prevented = true;
        },
      });
    }
    if (type === "submit" && !prevented) throw new Error("submit was not prevented");
  }

  text(): string {
    return (
      this.textContent +
      this.children.map((child) => (typeof child === "string" ? child : child.text())).join("")
    );
  }
}

class FakeDoc {
  createElement(tag: string): FakeEl {
    return new FakeEl(tag, this);
  }
}

function root(): FakeEl {
  return new FakeEl("div", new FakeDoc());
}

function all(node: FakeEl, className: string): FakeEl[] {
  const found: FakeEl[] = [];
  const walk = (current: FakeEl): void => {
    if (current.className.split(/\s+/).includes(className)) found.push(current);
    for (const child of current.children) {
      if (typeof child !== "string") walk(child);
    }
  };
  walk(node);
  return found;
}

function one(node: FakeEl, className: string): FakeEl {
  const [first] = all(node, className);
  if (first === undefined) throw new Error(`missing .${className}`);
  return first;
}

async function settle(): Promise<void> {
  await Promise.resolve();
  await Promise.resolve();
}

function harness(options: { copy?: (text: string) => Promise<void>; vanishFails?: boolean } = {}) {
  const mount = root();
  const copies: string[] = [];
  const vanished: number[] = [];
  const view = createIdentityView({
    mount: mount as unknown as HTMLElement,
    copy:
      options.copy ??
      (async (text: string) => {
        copies.push(text);
      }),
    onVanish: () => {
      vanished.push(Date.now());
      if (options.vanishFails === true) throw new Error("sweep failed");
    },
  });
  return { view, mount, copies, vanished };
}

// ---------------------------------------------------------------------------

describe("identity line", () => {
  it("shows the zifiri1 line, an 8-character fingerprint and the warning", () => {
    const h = harness();
    h.view.show(SEED, 7);

    const line = one(h.mount, "identity-line");
    expect(line.textContent).toBe(LINE);
    expect(line.textContent?.startsWith("zifiri1")).toBe(true);
    expect(line.textContent).toHaveLength(71);

    const fp = one(h.mount, "identity-fp-value");
    expect(fp.textContent).toBe(shortFingerprint(SEED));
    expect(fp.textContent).toHaveLength(FINGERPRINT_LENGTH);
    expect(fp.textContent).toMatch(/^[a-z2-7]{8}$/);

    expect(one(h.mount, "identity-warning").textContent).toBe(LOST_WARNING);
    expect(h.mount.text()).toContain("Bu satırı kaybedersen kimliğin gider.");
  });

  it("derives a different fingerprint per seed and never the line", () => {
    const h = harness();
    h.view.show(SEED, 7);
    expect(shortFingerprint(SEED)).not.toBe(shortFingerprint(OTHER));
    expect(shortFingerprint(SEED)).not.toContain(LINE.slice(7, 15));
    expect(h.view.fingerprint()).toBe(shortFingerprint(SEED));
    expect(h.view.state().nextI).toBe(7);
  });

  it("rejects a seed of the wrong length instead of drawing a fake line", () => {
    const h = harness();
    expect(() => h.view.show(new Uint8Array(16), 0)).toThrow();
    expect(h.view.state().kind).toBe("none");
  });
});

describe("copy", () => {
  it("copies the exact line and says so", async () => {
    const h = harness();
    h.view.show(SEED, 7);

    expect(await h.view.copyLine()).toBe(true);
    expect(h.copies).toEqual([LINE]);
    expect(one(h.mount, "identity-status").textContent).toBe("Satır kopyalandı.");
  });

  it("offers a manual fallback when the clipboard refuses", async () => {
    const h = harness({
      copy: async () => {
        throw new Error("denied");
      },
    });
    h.view.show(SEED, 7);

    expect(await h.view.copyLine()).toBe(false);
    expect(one(h.mount, "identity-status").textContent).toContain("elle kopyala");
  });

  it("does nothing when there is no identity", async () => {
    const h = harness();
    expect(await h.view.copyLine()).toBe(false);
    expect(h.copies).toHaveLength(0);
  });
});

describe("import", () => {
  it("round-trips an exported line", () => {
    const h = harness();
    const result = h.view.importLine(LINE);

    expect(result.ok).toBe(true);
    expect(h.view.line()).toBe(LINE);
    expect(h.view.state().nextI).toBe(7);
    expect(h.view.state().kind).toBe("ready");
    expect(one(h.mount, "identity-line").textContent).toBe(LINE);
    expect(one(h.mount, "identity-import-status").textContent).toBe("Kimlik içe aktarıldı.");
  });

  it("accepts a line pasted in caps, and clears the field", () => {
    const h = harness();
    const input = one(h.mount, "identity-import-input");
    input.value = LINE.toUpperCase();

    one(h.mount, "identity-import").fire("submit");

    expect(h.view.line()).toBe(LINE);
    expect(importIdentity(LINE).nextI).toBe(7);
    expect(input.value).toBe("");
  });

  it("refuses every malformed line without echoing it", () => {
    const h = harness();
    const corrupted = `${LINE.slice(0, 20)}${LINE[20] === "a" ? "b" : "a"}${LINE.slice(21)}`;
    const cases: { text: string; code: string }[] = [
      { text: "", code: "empty" },
      { text: "selam", code: "prefix" },
      { text: `${LINE.slice(0, 20)}!${LINE.slice(21)}`, code: "charset" },
      { text: LINE.slice(0, -1), code: "length" },
      { text: corrupted, code: "checksum" },
    ];

    for (const item of cases) {
      const result = h.view.importLine(item.text);
      expect(result.ok).toBe(false);
      if (result.ok) continue;
      expect(result.code).toBe(item.code);
      // The status line must never repeat what was pasted.
      const status = one(h.mount, "identity-import-status").textContent ?? "";
      expect(status.length).toBeGreaterThan(0);
      if (item.text.length >= 8) expect(status).not.toContain(item.text.slice(0, 8));
      expect(status).not.toContain("!");
    }

    expect(h.view.state().kind).toBe("none");
  });
});

describe("danger zone", () => {
  it("needs an identity before it can be armed", () => {
    const h = harness();
    expect(h.view.armVanish()).toBe(false);
    expect(one(h.mount, "identity-danger-status").textContent).toContain("kimlik");
  });

  it("is two steps: no confirmation before arming", async () => {
    const h = harness();
    h.view.show(SEED, 7);

    const early = await h.view.confirmVanish(VANISH_PHRASE);
    expect(early).toEqual({ ok: false, reason: "not-armed" });
    expect(h.vanished).toHaveLength(0);
    expect(one(h.mount, "identity-confirm").hidden).toBe(true);
  });

  it("arms, then refuses a wrong phrase", async () => {
    const h = harness();
    h.view.show(SEED, 7);
    expect(h.view.armVanish()).toBe(true);
    expect(one(h.mount, "identity-confirm").hidden).toBe(false);

    const wrong = await h.view.confirmVanish("yok");
    expect(wrong).toEqual({ ok: false, reason: "phrase" });
    expect(h.vanished).toHaveLength(0);
    expect(h.view.state().danger).toBe("armed");
    // The instruction is repeated; the typed text is not.
    expect(one(h.mount, "identity-danger-status").textContent).toBe('Onay için "yok ol" yaz.');
  });

  it("accepts the phrase in any Turkish casing, once", async () => {
    const h = harness();
    h.view.show(SEED, 7);
    h.view.armVanish();

    for (const phrase of ["yok ol", "YOK OL", "Yok Ol", "  yok   ol  ", "YOK OL"]) {
      expect(matchesVanishPhrase(phrase)).toBe(true);
    }

    const result = await h.view.confirmVanish("YOK OL");
    expect(result).toEqual({ ok: true });
    expect(h.vanished).toHaveLength(1);
    expect(h.view.state().danger).toBe("confirmed");
    expect(h.view.state().vanished).toBe(true);
    expect(one(h.mount, "identity-danger-status").textContent).toContain("geri alınamaz");

    const again = await h.view.confirmVanish("yok ol");
    expect(again).toEqual({ ok: false, reason: "done" });
    expect(h.vanished).toHaveLength(1);
  });

  it("does not treat near-misses as consent", () => {
    for (const phrase of ["yok ol!", "yokol", "yok", "", "evet", "sil"]) {
      expect(matchesVanishPhrase(phrase)).toBe(false);
    }
  });

  it("cancels back to idle, and a failed sweep re-arms", async () => {
    const h = harness();
    h.view.show(SEED, 7);
    h.view.armVanish();
    h.view.cancelVanish();
    expect(h.view.state().danger).toBe("idle");
    expect(await h.view.confirmVanish(VANISH_PHRASE)).toEqual({ ok: false, reason: "not-armed" });

    const failing = harness({ vanishFails: true });
    failing.view.show(SEED, 7);
    failing.view.armVanish();
    expect(await failing.view.confirmVanish(VANISH_PHRASE)).toEqual({ ok: false, reason: "failed" });
    expect(failing.view.state().vanished).toBe(false);
    expect(failing.view.state().danger).toBe("armed");
    expect(one(failing.mount, "identity-danger-status").textContent).toContain("tamamlanamadı");
  });

  it("runs the whole two-step flow from the buttons", async () => {
    const h = harness();
    h.view.show(SEED, 7);

    one(h.mount, "identity-arm").fire("click");
    await settle();
    expect(one(h.mount, "identity-confirm").hidden).toBe(false);

    const input = one(h.mount, "identity-confirm-input");
    input.value = "yok ol";
    one(h.mount, "identity-confirm-button").fire("click");
    await settle();

    expect(h.vanished).toHaveLength(1);
    expect(one(h.mount, "identity-arm").disabled).toBe(true);
  });
});
