import { describe, expect, it, vi } from "vitest";
import {
  createDm,
  DmError,
  formatPeerFingerprint,
  peerFingerprint,
  presenceState,
  renderDm,
  summarize,
  unreadCount,
  type Dm,
  type DmDeps,
  type DmThread,
  type MailboxEnvelope,
} from "../src/ui/dm";
import { utf8ToBytes } from "@noble/hashes/utils.js";

/**
 * The fake crypto here is deliberately dumb — a JSON body tagged with the
 * recipient key — because these tests are about the *bookkeeping* around a
 * sealed envelope (cursor, decoys, TTL, unread), not about the seal itself.
 * The one property that matters is preserved: an envelope addressed to someone
 * else cannot be opened, and that must look like silence, not like an error.
 */

const NOW = 1_700_000_000_000;
const ME = key(0x11);
const PEER_A = key(0x22);
const PEER_B = key(0x33);

function key(byte: number): Uint8Array {
  return Uint8Array.from({ length: 32 }, () => byte);
}

function hex(bytes: Uint8Array): string {
  return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function sealBody(to: Uint8Array, text: string, from: Uint8Array = ME): Uint8Array {
  return utf8ToBytes(JSON.stringify({ to: hex(to), from: hex(from), text }));
}

function openBody(body: Uint8Array): { from: string; text: string } | null {
  const parsed = JSON.parse(new TextDecoder().decode(body)) as {
    to?: unknown;
    from?: unknown;
    text?: unknown;
  };
  if (parsed.to !== hex(ME)) return null;
  if (typeof parsed.from !== "string" || typeof parsed.text !== "string") return null;
  return { from: parsed.from, text: parsed.text };
}

interface Harness {
  dm: Dm;
  mailbox: MailboxEnvelope[];
  /** Bodies handed to `deliver`: they go to the *peer's* mailbox, not ours. */
  delivered: Uint8Array[];
  fetchCalls: (string | null)[];
  openCalls: number;
  presenceCalls: number;
}

function harness(overrides: Partial<DmDeps> = {}): Harness {
  const mailbox: MailboxEnvelope[] = [];
  const delivered: Uint8Array[] = [];
  const fetchCalls: (string | null)[] = [];
  const state: Harness = {
    dm: undefined as unknown as Dm,
    mailbox,
    delivered,
    fetchCalls,
    openCalls: 0,
    presenceCalls: 0,
  };

  const deps: DmDeps = {
    seal: (peer, text) => sealBody(peer, text),
    open: (body) => {
      state.openCalls += 1;
      return openBody(body);
    },
    deliver: (body) => {
      if (body instanceof Uint8Array) delivered.push(body);
    },
    fetchMailbox: (since) => {
      fetchCalls.push(since);
      const start = since === null ? 0 : Number.parseInt(since.slice(1), 10);
      const page = mailbox.slice(Number.isNaN(start) ? 0 : start);
      return { envelopes: page, since: `c${mailbox.length}` };
    },
    now: () => NOW,
    ...overrides,
  };

  state.dm = createDm(deps);
  return state;
}

function envelope(overrides: Partial<MailboxEnvelope> = {}): MailboxEnvelope {
  return {
    id: "x1",
    body: sealBody(ME, "hello"),
    expiresAt: NOW + 1000,
    ...overrides,
  };
}

// ---------------------------------------------------------------------------
// Fake DOM: the same minimal shape `renderChat` is tested against, so these
// tests stay in the node environment.
// ---------------------------------------------------------------------------

class FakeElement {
  className = "";
  textContent = "";
  children: FakeElement[] = [];
  dataset: Record<string, string> = {};

  constructor(
    readonly tagName: string,
    readonly ownerDocument: FakeDocument,
  ) {}

  append(...nodes: FakeElement[]): void {
    this.children.push(...nodes);
  }

  replaceChildren(...nodes: FakeElement[]): void {
    this.children = nodes;
  }

  allText(): string {
    return this.textContent + this.children.map((child) => child.allText()).join("");
  }

  classNames(): string[] {
    return [this.className, ...this.children.flatMap((child) => child.classNames())].filter(Boolean);
  }
}

class FakeDocument {
  createElement(tag: string): FakeElement {
    return new FakeElement(tag, this);
  }
}

function fakeRoot(): FakeElement {
  const doc = new FakeDocument();
  return new FakeElement("div", doc);
}

function thread(overrides: Partial<DmThread> = {}): DmThread {
  return {
    peer: hex(PEER_A),
    peerKey: PEER_A,
    messages: [],
    lastText: "",
    lastAt: 0,
    unread: 0,
    presence: "unknown",
    ...overrides,
  };
}

// ---------------------------------------------------------------------------

describe("send", () => {
  it("seals, delivers, and shows the message as sent with no unread", async () => {
    const h = harness();
    const message = await h.dm.send(PEER_A, "hello");

    expect(h.delivered).toHaveLength(1);
    expect(h.mailbox).toHaveLength(0);
    expect(message.self).toBe(true);
    expect(message.unread).toBe(false);

    const [only] = h.dm.threads();
    expect(only?.peer).toBe(hex(PEER_A));
    expect(only?.lastText).toBe("hello");
    expect(only?.unread).toBe(0);
    expect(unreadCount(h.dm.threads())).toBe(0);
  });

  it("refuses an empty message before sealing anything", async () => {
    const h = harness();
    await expect(h.dm.send(PEER_A, "   ")).rejects.toBeInstanceOf(DmError);
    expect(h.delivered).toHaveLength(0);
  });
});

describe("pull", () => {
  it("opens a real envelope into a thread and counts it unread", async () => {
    const h = harness();
    await h.dm.send(PEER_A, "giden");
    // The sealed body goes to PEER_A's mailbox; our own mailbox holds the reply.
    h.mailbox.push({ id: "in1", body: sealBody(ME, "gelen", PEER_A), expiresAt: NOW + 1000 });

    const result = await h.dm.pull();

    expect(h.delivered).toHaveLength(1);
    expect(result.opened).toBe(1);
    expect(result.skipped).toBe(0);
    const [only] = h.dm.threads();
    expect(only?.messages.map((m) => m.text)).toEqual(["giden", "gelen"]);
    expect(only?.unread).toBe(1);
    expect(unreadCount(h.dm.threads())).toBe(1);
  });

  it("hands the cursor back on the next pull", async () => {
    const h = harness();
    await h.dm.pull();
    expect(h.fetchCalls).toEqual([null]);
    expect(h.dm.cursor()).toBe("c0");

    h.mailbox.push({ id: "in1", body: sealBody(ME, "yeni"), expiresAt: NOW + 1000 });
    await h.dm.pull();

    expect(h.fetchCalls).toEqual([null, "c0"]);
    expect(h.dm.cursor()).toBe("c1");
    expect(h.dm.threads()[0]?.unread).toBe(1);
  });

  it("skips a decoy addressed to someone else without throwing", async () => {
    const h = harness();
    h.mailbox.push({ id: "d1", body: sealBody(PEER_B, "not for you"), expiresAt: NOW + 1000 });

    const result = await h.dm.pull();

    expect(result.opened).toBe(0);
    expect(result.skipped).toBe(1);
    expect(h.dm.threads()).toEqual([]);
  });

  it("treats an open() that throws as one more decoy", async () => {
    const h = harness();
    h.mailbox.push({ id: "bad", body: utf8ToBytes("not json"), expiresAt: NOW + 1000 });

    const result = await h.dm.pull();

    expect(result.skipped).toBe(1);
    expect(h.dm.threads()).toEqual([]);
  });

  it("drops an expired envelope before it ever reaches open()", async () => {
    const h = harness();
    h.mailbox.push(envelope({ id: "old", expiresAt: NOW - 1 }));

    const result = await h.dm.pull();

    expect(result.expired).toBe(1);
    expect(result.opened).toBe(0);
    expect(h.openCalls).toBe(0);
    expect(h.dm.threads()).toEqual([]);
  });

  it("counts a repeated envelope id once", async () => {
    const h = harness();
    h.mailbox.push(envelope({ id: "same" }), envelope({ id: "same" }));

    const result = await h.dm.pull();

    expect(result.opened).toBe(1);
    expect(result.duplicates).toBe(1);
    expect(h.dm.threads()[0]?.unread).toBe(1);
  });

  it("keeps one thread per peer, newest conversation first", async () => {
    const h = harness();
    h.mailbox.push(
      { id: "a1", body: sealBody(ME, "A eski", PEER_A), expiresAt: NOW + 1000 },
      { id: "b1", body: sealBody(ME, "B yeni", PEER_B), expiresAt: NOW + 1000 },
    );

    await h.dm.pull();
    const threads = h.dm.threads();

    expect(threads).toHaveLength(2);
    expect(threads.map((t) => t.lastText).sort()).toEqual(["A eski", "B yeni"]);
    expect(unreadCount(threads)).toBe(2);
  });

  it("keeps decoys out of the unread count even in a full bucket", async () => {
    const h = harness();
    for (let i = 0; i < 119; i += 1) {
      h.mailbox.push({ id: `d${i}`, body: sealBody(PEER_B, "decoy"), expiresAt: NOW + 1000 });
    }
    h.mailbox.push({ id: "real", body: sealBody(ME, "real"), expiresAt: NOW + 1000 });

    const result = await h.dm.pull();

    expect(result.opened).toBe(1);
    expect(result.skipped).toBe(119);
    expect(unreadCount(h.dm.threads())).toBe(1);
  });
});

describe("unreadCount", () => {
  it("sums threads and ignores zero", () => {
    expect(unreadCount([thread({ unread: 2 }), thread({ unread: 0 }), thread({ unread: 3 })])).toBe(5);
  });

  it("never returns a negative or fractional total", () => {
    expect(unreadCount([thread({ unread: -4 }), thread({ unread: 2.9 })])).toBe(2);
  });

  it("is zero for an empty list", () => {
    expect(unreadCount([])).toBe(0);
  });
});

describe("markRead", () => {
  it("clears one conversation and leaves the other alone", async () => {
    const h = harness();
    h.mailbox.push(
      { id: "a1", body: sealBody(ME, "A", PEER_A), expiresAt: NOW + 1000 },
      { id: "b1", body: sealBody(ME, "B", PEER_B), expiresAt: NOW + 1000 },
    );
    await h.dm.pull();

    h.dm.markRead(PEER_A);

    const byPeer = new Map(h.dm.threads().map((t) => [t.peer, t.unread]));
    expect(byPeer.get(hex(PEER_A))).toBe(0);
    expect(byPeer.get(hex(PEER_B))).toBe(1);
    expect(unreadCount(h.dm.threads())).toBe(1);
  });
});

describe("presence", () => {
  it("makes no request at all when disabled", async () => {
    const request = vi.fn(async () => ({ lastSeen: NOW }));
    const label = await presenceState(PEER_A, false, request, () => NOW);

    expect(label).toBe("unknown");
    expect(request).not.toHaveBeenCalled();
  });

  it("does not request presence through the bound method either", async () => {
    const h = harness({
      presence: () => {
        h.presenceCalls += 1;
        return { lastSeen: NOW };
      },
    });

    const label = await h.dm.presenceState(PEER_A, false);

    expect(label).toBe("unknown");
    expect(h.presenceCalls).toBe(0);
  });

  it("says online when the peer was seen inside the window", async () => {
    const label = await presenceState(PEER_A, true, async () => ({ lastSeen: NOW - 60_000 }), () => NOW);
    expect(label).toBe("online");
  });

  it("says 5+ min when the last sighting is older than five minutes", async () => {
    const label = await presenceState(PEER_A, true, async () => ({ lastSeen: NOW - 6 * 60_000 }), () => NOW);
    expect(label).toBe("5+ min");
  });

  it("falls back to unknown when the probe fails or answers nothing", async () => {
    const failing = await presenceState(
      PEER_A,
      true,
      async () => {
        throw new Error("offline");
      },
      () => NOW,
    );
    const empty = await presenceState(PEER_A, true, async () => null, () => NOW);

    expect(failing).toBe("unknown");
    expect(empty).toBe("unknown");
  });

  it("stores the label on the existing thread when asked", async () => {
    const h = harness({ presence: () => ({ lastSeen: NOW }) });
    await h.dm.send(PEER_A, "hello");

    const label = await h.dm.presenceState(PEER_A, true);

    expect(label).toBe("online");
    expect(h.dm.threads()[0]?.presence).toBe("online");
  });
});

describe("identity label", () => {
  it("is a 13-character base32 fingerprint, grouped for reading", () => {
    const fingerprint = peerFingerprint(PEER_A);
    expect(fingerprint).toMatch(/^[a-z2-7]{13}$/);
    expect(formatPeerFingerprint(fingerprint)).toBe(
      `${fingerprint.slice(0, 4)}-${fingerprint.slice(4, 8)}-${fingerprint.slice(8)}`,
    );
    expect(peerFingerprint(PEER_B)).not.toBe(fingerprint);
  });

  it("collapses whitespace and truncates a long preview", () => {
    expect(summarize("  two\n lines  ")).toBe("two lines");
    const long = "a".repeat(200);
    expect(summarize(long, 10)).toBe(`${"a".repeat(9)}…`);
  });
});

describe("renderDm", () => {
  it("shows an empty state rather than a blank list", () => {
    const root = fakeRoot();
    renderDm(root as unknown as HTMLElement, []);

    expect(root.allText()).toContain("You have not talked to anyone yet");
    expect(root.classNames()).toContain("empty");
  });

  it("labels a peer by fingerprint and shows preview plus unread badge", () => {
    const root = fakeRoot();
    const label = formatPeerFingerprint(peerFingerprint(PEER_A));
    renderDm(root as unknown as HTMLElement, [
      thread({ lastText: "last message", unread: 2, presence: "online" }),
    ]);

    const list = root.children[0];
    const button = list?.children[0]?.children[0];
    expect(button?.dataset.peer).toBe(hex(PEER_A));
    expect(button?.children[0]?.textContent).toBe(label);
    expect(button?.children[1]?.textContent).toBe("last message");
    expect(button?.children[2]?.textContent).toBe("online");
    expect(button?.children[3]?.textContent).toBe("2 unread");
    expect(root.allText()).not.toContain(hex(PEER_A));
  });

  it("keeps markup in a preview as text", () => {
    const root = fakeRoot();
    const payload = '<img src=x onerror="alert(1)">';
    renderDm(root as unknown as HTMLElement, [thread({ lastText: payload })]);

    expect(root.allText()).toContain(payload);
    expect(root.classNames().some((name) => name.includes("img"))).toBe(false);
  });

  it("renders an unread-free thread without a badge", () => {
    const root = fakeRoot();
    renderDm(root as unknown as HTMLElement, [thread({ lastText: "okundu" })]);

    const button = root.children[0]?.children[0]?.children[0];
    expect(button?.children).toHaveLength(3);
    expect(root.allText()).not.toContain("unread");
  });
});
