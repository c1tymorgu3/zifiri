import { describe, expect, it, vi } from "vitest";
import {
  clockLabel,
  createDmView,
  MAX_BODY,
  relativeLabel,
  type DmView,
} from "../src/ui/dm-view";
import {
  formatPeerFingerprint,
  peerFingerprint,
  type DmMessage,
  type DmThread,
  type PresenceReading,
} from "../src/ui/dm";

const NOW = 1_700_000_000_000;

function key(byte: number): Uint8Array {
  return Uint8Array.from({ length: 32 }, () => byte);
}

const PEER_A = key(0x22);
const PEER_B = key(0x33);
const PEER_A_ID = "aa".repeat(32);
const PEER_B_ID = "bb".repeat(32);

function fp(peer: Uint8Array): string {
  return formatPeerFingerprint(peerFingerprint(peer));
}

function message(overrides: Partial<DmMessage> = {}): DmMessage {
  return {
    id: "m1",
    peer: PEER_A_ID,
    text: "hello",
    at: NOW,
    self: false,
    unread: true,
    ...overrides,
  };
}

function thread(overrides: Partial<DmThread> = {}): DmThread {
  return {
    peer: PEER_A_ID,
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
// Minimal fake DOM. Same shape the other view tests use: createElement,
// append/replaceChildren, listeners, and just enough element state to assert
// what the user would actually see.
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
  rows = 0;

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

interface Harness {
  view: DmView;
  mount: FakeEl;
  sent: { peer: string; text: string; mode: string }[];
  opened: string[];
  probes: string[];
  reading: PresenceReading | null;
}

function harness(options: { presenceEnabled?: boolean; fail?: boolean } = {}): Harness {
  const mount = root();
  const state: Harness = {
    view: undefined as unknown as DmView,
    mount,
    sent: [],
    opened: [],
    probes: [],
    reading: { lastSeen: NOW },
  };

  state.view = createDmView({
    mount: mount as unknown as HTMLElement,
    now: () => NOW,
    ...(options.presenceEnabled === true ? { presenceEnabled: true } : {}),
    presence: (peer) => {
      state.probes.push(Array.from(peer).map((b) => b.toString(16).padStart(2, "0")).join("").slice(0, 4));
      return state.reading;
    },
    onSend: (peer, text, mode) => {
      if (options.fail === true) throw new Error("network down");
      state.sent.push({ peer, text, mode });
    },
    onOpen: (peer) => state.opened.push(peer),
  });

  return state;
}

/** Waits for the microtask queue so a fire-and-forget handler settles. */
async function settle(): Promise<void> {
  await Promise.resolve();
  await Promise.resolve();
}

// ---------------------------------------------------------------------------

describe("presence", () => {
  it("makes no request at all while it is off", async () => {
    const h = harness();
    h.view.setThreads([thread({ messages: [message()], lastText: "hello", lastAt: NOW })]);

    const label = await h.view.select(PEER_A_ID);
    await h.view.refreshPresence();
    await h.view.setPresenceEnabled(false);

    expect(label).toBe("unknown");
    expect(h.probes).toHaveLength(0);
    expect(h.view.state().presence).toBe("unknown");
    expect(one(h.mount, "dm-presence-text").textContent).toBe("unknown");
    expect(all(h.mount, "dm-dot")).toHaveLength(0);
  });

  it("probes once per open conversation when the user turns it on", async () => {
    const h = harness({ presenceEnabled: true });
    h.view.setThreads([
      thread({ messages: [message()], lastText: "hello", lastAt: NOW }),
      thread({ peer: PEER_B_ID, peerKey: PEER_B, messages: [message()], lastText: "hello" }),
    ]);

    await h.view.select(PEER_A_ID);
    expect(h.probes).toHaveLength(1);
    expect(h.view.state().presence).toBe("online");
    expect(one(h.mount, "dm-presence-text").textContent).toBe("online");
    expect(one(h.mount, "dm-dot").className).toContain("dm-dot--ok");

    await h.view.select(PEER_B_ID);
    expect(h.probes).toHaveLength(2);
  });

  it("drops the dot and the cached label when switched off", async () => {
    const h = harness({ presenceEnabled: true });
    h.view.setThreads([thread({ messages: [message()], lastText: "hello" })]);
    await h.view.select(PEER_A_ID);
    expect(all(h.mount, "dm-dot").length).toBeGreaterThan(0);

    await h.view.setPresenceEnabled(false);
    await h.view.refreshPresence();

    expect(h.probes).toHaveLength(1);
    expect(all(h.mount, "dm-dot")).toHaveLength(0);
    expect(one(h.mount, "dm-presence-text").textContent).toBe("unknown");
  });

  it("reads a stale peer as \"5+ min\" and pairs the dot with the word", async () => {
    const h = harness({ presenceEnabled: true });
    h.reading = { lastSeen: NOW - 20 * 60_000 };
    h.view.setThreads([thread()]);

    const label = await h.view.select(PEER_A_ID);

    expect(label).toBe("5+ min");
    expect(one(h.mount, "dm-dot").className).toContain("dm-dot--idle");
    expect(one(h.mount, "dm-presence-text").textContent).toBe("5+ min");
  });
});

describe("conversation list", () => {
  it("shows the peer fingerprint, the last message and the unread count", () => {
    const h = harness();
    h.view.setThreads([
      thread({
        messages: [message({ text: "gelen" })],
        lastText: "gelen",
        lastAt: NOW - 3 * 60_000,
        unread: 2,
      }),
      thread({
        peer: PEER_B_ID,
        peerKey: PEER_B,
        messages: [message({ peer: PEER_B_ID })],
        lastText: "yeni",
        lastAt: NOW,
        unread: 1,
      }),
    ]);

    const rows = all(h.mount, "dm-row");
    expect(rows).toHaveLength(2);
    expect(one(rows[0] as FakeEl, "dm-fp").textContent).toBe(fp(PEER_A));
    expect(one(rows[0] as FakeEl, "dm-preview").textContent).toBe("gelen");
    expect(one(rows[0] as FakeEl, "dm-when").textContent).toBe("3 min");
    expect(one(rows[0] as FakeEl, "dm-unread").textContent).toBe("2");
    expect(one(rows[0] as FakeEl, "dm-unread").getAttribute("aria-label")).toBe("2 unread");
    expect(h.view.state().unread).toBe(3);
  });

  it("marks the open row and opens a conversation on click", async () => {
    const h = harness();
    h.view.setThreads([thread({ messages: [message()] })]);

    const [row] = all(h.mount, "dm-row");
    expect(row).toBeDefined();
    (row as FakeEl).fire("click");
    await settle();

    expect(h.view.state().selected).toBe(PEER_A_ID);
    expect(h.opened).toEqual([PEER_A_ID]);
    // The list is rebuilt, so the mark lives on the new node.
    expect(one(h.mount, "dm-row").getAttribute("aria-current")).toBe("true");
  });

  it("explains an empty list in one sentence", () => {
    const h = harness();
    h.view.setThreads([]);
    expect(one(h.mount, "dm-empty").textContent).toBe("You have not talked to anyone yet.");
    expect(one(h.mount, "dm-pick").textContent).toContain("Pick a row on the left");
  });

  it("drops the selection when its thread disappears", () => {
    const h = harness();
    h.view.setThreads([thread()]);
    void h.view.select(PEER_A_ID);
    h.view.setThreads([]);
    expect(h.view.state().selected).toBeNull();
  });
});

describe("thread", () => {
  it("renders hairline rows, not bubbles: clock, optional tag, text", () => {
    const h = harness();
    h.view.setThreads([
      thread({
        messages: [
          message({ id: "1", text: "giden", at: NOW, self: true, unread: false }),
          message({ id: "2", text: "gelen", at: NOW + 60_000, self: false }),
        ],
        lastText: "gelen",
        lastAt: NOW,
      }),
    ]);
    void h.view.select(PEER_A_ID);

    const rows = all(h.mount, "dm-msg");
    expect(rows).toHaveLength(2);
    expect((rows[0] as FakeEl).dataset.self).toBe("1");
    expect((rows[0] as FakeEl).dataset.self).not.toBe((rows[1] as FakeEl).dataset.self);
    expect(one(rows[0] as FakeEl, "dm-clock").textContent).toBe(clockLabel(NOW));
    expect(one(rows[0] as FakeEl, "dm-text").textContent).toBe("giden");
    // No name tag: own messages are told apart by data-self and the CSS indent.
    expect(rows[0]?.text()).not.toContain("sen");
    expect(one(rows[1] as FakeEl, "dm-text").textContent).toBe("gelen");
    expect(one(h.mount, "dm-thread-head").text().includes(fp(PEER_A))).toBe(true);
  });

  it("keeps message text as text", () => {
    const h = harness();
    const raw = '<img src=x onerror="alert(1)">';
    h.view.setThreads([thread({ messages: [message({ text: raw })], lastText: raw })]);
    void h.view.select(PEER_A_ID);

    expect(one(h.mount, "dm-text").textContent).toBe(raw);
    expect(all(h.mount, "img")).toHaveLength(0);
  });
});

describe("composer", () => {
  it("refuses an empty or whitespace draft without calling the transport", async () => {
    const h = harness();
    h.view.setThreads([thread()]);
    await h.view.select(PEER_A_ID);

    expect(one(h.mount, "dm-send").disabled).toBe(true);
    expect(await h.view.submit()).toBe(false);

    h.view.setDraft("   ");
    expect(one(h.mount, "dm-send").disabled).toBe(true);
    expect(await h.view.submit()).toBe(false);
    expect(h.sent).toHaveLength(0);
  });

  it("trims, sends, clears the draft and reports success", async () => {
    const h = harness();
    h.view.setThreads([thread()]);
    await h.view.select(PEER_A_ID);

    h.view.setDraft("  hello  ");
    expect(one(h.mount, "dm-count").textContent).toBe("9 / " + MAX_BODY);
    expect(one(h.mount, "dm-send").disabled).toBe(false);

    expect(await h.view.submit()).toBe(true);
    expect(h.sent).toEqual([{ peer: PEER_A_ID, text: "hello", mode: "silent" }]);
    expect(h.view.state().draft).toBe("");
    expect(one(h.mount, "dm-count").textContent).toBe("0 / " + MAX_BODY);
    expect(one(h.mount, "dm-status").textContent).toBe("Sent.");
  });

  it("keeps the draft when the transport rejects", async () => {
    const h = harness({ fail: true });
    h.view.setThreads([thread()]);
    await h.view.select(PEER_A_ID);
    h.view.setDraft("do not lose it");

    expect(await h.view.submit()).toBe(false);
    expect(h.view.state().draft).toBe("do not lose it");
    expect(one(h.mount, "dm-status").textContent).toContain("Could not send");
  });

  it("caps the draft at MAX_BODY", () => {
    const h = harness();
    h.view.setThreads([thread()]);
    h.view.setDraft("a".repeat(MAX_BODY + 50));
    expect(h.view.state().draft).toHaveLength(MAX_BODY);
  });
});

describe("mode switch", () => {
  it("starts silent, with the consequence spelled out", async () => {
    const h = harness();
    h.view.setThreads([thread()]);
    await h.view.select(PEER_A_ID);

    expect(h.view.state().mode).toBe("silent");
    expect(one(h.mount, "dm-mode-note").textContent).toContain("~99%");
    expect(one(h.mount, "dm-mode-note").textContent).toContain("10-minute");
  });

  it("asks once before fast, and only changes on the yes", async () => {
    const h = harness();
    h.view.setThreads([thread()]);
    await h.view.select(PEER_A_ID);

    h.view.setMode("fast");
    expect(h.view.state().mode).toBe("silent");
    expect(h.view.state().askMode).toBe(true);
    expect(one(h.mount, "dm-mode-ask").hidden).toBe(false);
    expect(one(h.mount, "dm-mode-ask-text").textContent).toContain("Fast mode");

    h.view.cancelFastMode();
    expect(h.view.state().askMode).toBe(false);
    expect(h.view.state().mode).toBe("silent");
    expect(one(h.mount, "dm-mode-ask").hidden).toBe(true);

    h.view.setMode("fast");
    h.view.confirmFastMode();
    expect(h.view.state().mode).toBe("fast");
    expect(one(h.mount, "dm-mode-note").textContent).toContain("~80%");

    // Asked once: going back and forth does not ask again.
    h.view.setMode("silent");
    h.view.setMode("fast");
    expect(h.view.state().mode).toBe("fast");
    expect(h.view.state().askMode).toBe(false);
  });

  it("sends the draft with the chosen mode", async () => {
    const h = harness();
    h.view.setThreads([thread()]);
    await h.view.select(PEER_A_ID);
    h.view.setMode("fast");
    h.view.confirmFastMode();
    h.view.setDraft("now");

    expect(await h.view.submit()).toBe(true);
    expect(h.sent[0]?.mode).toBe("fast");
  });
});

describe("loading", () => {
  it("shows static skeleton rows instead of a spinner", () => {
    const h = harness();
    h.view.setLoading(true);

    expect(all(h.mount, "dm-skeleton")).toHaveLength(3);
    expect(h.mount.text()).toContain("Loading conversations.");
    expect(h.view.state().loading).toBe(true);

    h.view.setLoading(false);
    expect(all(h.mount, "dm-skeleton")).toHaveLength(0);
    expect(one(h.mount, "dm-empty").textContent).toBe("You have not talked to anyone yet.");
  });
});

describe("time labels", () => {
  it("formats a clock and relative time without inventing values", () => {
    expect(clockLabel(0)).toBe("--:--");
    expect(clockLabel(NOW)).toMatch(/^\d{2}:\d{2}$/);
    expect(relativeLabel(NOW, NOW)).toBe("now");
    expect(relativeLabel(NOW - 59_000, NOW)).toBe("now");
    expect(relativeLabel(NOW - 3 * 60_000, NOW)).toBe("3 min");
    expect(relativeLabel(NOW - 2 * 3_600_000, NOW)).toBe("2 h");
    expect(relativeLabel(NOW - 4 * 86_400_000, NOW)).toBe("4 d");
    expect(relativeLabel(0, NOW)).toBe("");
  });
});
