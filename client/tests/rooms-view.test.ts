import { describe, expect, it } from "vitest";
import {
  CHAR_LIMIT,
  clockLabel,
  createRoomsView,
  EMPTY_MESSAGES,
  EMPTY_ROOMS,
  NO_ROOM,
  relativeTime,
  renderMessageStream,
  renderRoomList,
  SILENT_WAIT,
  sortRooms,
  type RoomMessage,
  type RoomsView,
  type RoomsViewOptions,
  type RoomSummary,
} from "../src/ui/rooms-view";
import { DEFAULT_MODE, describeMode } from "../src/ui/mode";

const NOW = 1_700_000_000_000;
const MINUTE = 60_000;

function room(overrides: Partial<RoomSummary> = {}): RoomSummary {
  return {
    id: "genel",
    name: "genel",
    lastActivityAt: NOW,
    unread: 0,
    presence: false,
    ...overrides,
  };
}

function message(overrides: Partial<RoomMessage> = {}): RoomMessage {
  return { id: "m1", body: "merhaba", at: NOW, ...overrides };
}

// ---------------------------------------------------------------------------
// Minimal fake DOM, the same shape the other view tests use.
// ---------------------------------------------------------------------------

type Handler = (event: FakeEvent) => void;

interface FakeEvent {
  defaultPrevented: boolean;
  preventDefault(): void;
}

class FakeEl {
  className = "";
  textContent = "";
  children: (FakeEl | string)[] = [];
  attrs: Record<string, string> = {};
  listeners: Record<string, Handler[]> = {};
  id = "";
  name = "";
  value = "";
  checked = false;
  type = "";
  rows = 0;
  scrollTop = 0;
  scrollHeight = 0;
  parent: FakeEl | null = null;
  focused = false;

  constructor(
    readonly tagName: string,
    readonly ownerDocument: FakeDoc,
  ) {}

  append(...nodes: (FakeEl | string)[]): void {
    for (const node of nodes) {
      this.children.push(node);
      if (node instanceof FakeEl) node.parent = this;
    }
  }

  replaceChildren(...nodes: (FakeEl | string)[]): void {
    this.children = [];
    this.append(...nodes);
  }

  remove(): void {
    if (this.parent !== null) {
      this.parent.children = this.parent.children.filter((child) => child !== this);
      this.parent = null;
    }
  }

  setAttribute(name: string, value: string): void {
    this.attrs[name] = value;
  }

  getAttribute(name: string): string | null {
    return this.attrs[name] ?? null;
  }

  removeAttribute(name: string): void {
    delete this.attrs[name];
  }

  hasAttribute(name: string): boolean {
    return name in this.attrs;
  }

  addEventListener(type: string, handler: Handler): void {
    const list = this.listeners[type] ?? [];
    list.push(handler);
    this.listeners[type] = list;
  }

  removeEventListener(type: string, handler: Handler): void {
    this.listeners[type] = (this.listeners[type] ?? []).filter((entry) => entry !== handler);
  }

  focus(): void {
    this.focused = true;
  }

  fire(type: string): void {
    let prevented = false;
    const event: FakeEvent = {
      defaultPrevented: false,
      preventDefault() {
        prevented = true;
        event.defaultPrevented = true;
      },
    };
    for (const handler of this.listeners[type] ?? []) handler(event);
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

  createElementNS(_namespace: string, tag: string): FakeEl {
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

function count(node: FakeEl, className: string): number {
  return all(node, className).length;
}

interface Harness {
  view: RoomsView;
  mount: FakeEl;
  sent: { roomId: string; body: string; mode: string }[];
  opened: string[];
}

function harness(options: Omit<RoomsViewOptions, "mount"> = {}): Harness {
  const mount = root();
  const state: Harness = {
    view: undefined as unknown as RoomsView,
    mount,
    sent: [],
    opened: [],
  };

  state.view = createRoomsView({
    now: () => NOW,
    ...options,
    mount: mount as unknown as HTMLElement,
    onSend: (sent) => state.sent.push({ roomId: sent.roomId, body: sent.body, mode: sent.mode }),
    onSelectRoom: (id) => state.opened.push(id),
  });

  return state;
}

function radio(host: FakeEl, value: string): FakeEl {
  const found = all(host, "zf-mode-input").find((input) => input.value === value);
  if (found === undefined) throw new Error(`missing radio ${value}`);
  return found;
}

// ---------------------------------------------------------------------------

describe("sortRooms", () => {
  it("puts the newest activity first", () => {
    const rooms = [
      room({ id: "a", name: "a", lastActivityAt: NOW - 5 * MINUTE }),
      room({ id: "b", name: "b", lastActivityAt: NOW }),
      room({ id: "c", name: "c", lastActivityAt: NOW - MINUTE }),
    ];

    expect(sortRooms(rooms).map((entry) => entry.id)).toEqual(["b", "c", "a"]);
  });

  it("breaks ties by name so the order never jitters", () => {
    const rooms = [
      room({ id: "z", name: "zebra", lastActivityAt: NOW }),
      room({ id: "a", name: "ada", lastActivityAt: NOW }),
    ];

    expect(sortRooms(rooms).map((entry) => entry.name)).toEqual(["ada", "zebra"]);
  });

  it("leaves the caller's array alone", () => {
    const rooms = [
      room({ id: "a", name: "a", lastActivityAt: NOW - MINUTE }),
      room({ id: "b", name: "b", lastActivityAt: NOW }),
    ];

    sortRooms(rooms);

    expect(rooms.map((entry) => entry.id)).toEqual(["a", "b"]);
  });
});

describe("relativeTime", () => {
  it("reads under a minute as now", () => {
    expect(relativeTime(NOW - 30_000, NOW)).toBe("şimdi");
  });

  it("counts minutes, hours and days", () => {
    expect(relativeTime(NOW - 3 * MINUTE, NOW)).toBe("3 dk");
    expect(relativeTime(NOW - 2 * 60 * MINUTE, NOW)).toBe("2 sa");
    expect(relativeTime(NOW - 4 * 24 * 60 * MINUTE, NOW)).toBe("4 g");
  });

  it("never shows a negative age when the clock runs backwards", () => {
    expect(relativeTime(NOW + MINUTE, NOW)).toBe("şimdi");
  });
});

describe("clockLabel", () => {
  it("is a zero-padded 24-hour clock", () => {
    expect(clockLabel(new Date(2026, 10, 22, 9, 5).getTime())).toBe("09:05");
    expect(clockLabel(new Date(2026, 10, 22, 17, 40).getTime())).toBe("17:40");
  });
});

describe("renderRoomList", () => {
  it("draws the rows newest first", () => {
    const host = root();
    renderRoomList(host as unknown as HTMLElement, [
      room({ id: "eski", name: "eski", lastActivityAt: NOW - 30 * MINUTE }),
      room({ id: "yeni", name: "yeni", lastActivityAt: NOW }),
    ], { now: NOW, activeId: null });

    expect(all(host, "zf-room").map((row) => row.getAttribute("data-room-id"))).toEqual([
      "yeni",
      "eski",
    ]);
  });

  it("shows the last activity in minutes", () => {
    const host = root();
    renderRoomList(host as unknown as HTMLElement, [
      room({ lastActivityAt: NOW - 3 * MINUTE }),
    ], { now: NOW, activeId: null });

    expect(one(host, "zf-room-time").textContent).toBe("3 dk");
    expect(one(host, "zf-room-time").getAttribute("datetime")).toBe(
      new Date(NOW - 3 * MINUTE).toISOString(),
    );
  });

  it("shows an unread count only when there is one", () => {
    const host = root();
    renderRoomList(host as unknown as HTMLElement, [
      room({ id: "a", name: "a", unread: 4 }),
      room({ id: "b", name: "b", unread: 0, lastActivityAt: NOW - MINUTE }),
    ], { now: NOW, activeId: null });

    expect(count(host, "zf-room-unread")).toBe(1);
    expect(one(host, "zf-room-unread").text()).toContain("4");
    // The word is in the DOM for a screen reader, not only a colour.
    expect(one(host, "zf-room-unread").text()).toContain("okunmamış");
  });

  it("draws a presence dot only when presence is on", () => {
    const host = root();
    renderRoomList(host as unknown as HTMLElement, [
      room({ id: "a", name: "a", presence: true }),
      room({ id: "b", name: "b", presence: false, lastActivityAt: NOW - MINUTE }),
    ], { now: NOW, activeId: null });

    expect(count(host, "zf-room-dot")).toBe(1);
    expect(one(host, "zf-room-dot").getAttribute("aria-label")).toBe("şu an açık");
  });

  it("marks exactly one row as the current room", () => {
    const host = root();
    renderRoomList(host as unknown as HTMLElement, [
      room({ id: "a", name: "a" }),
      room({ id: "b", name: "b", lastActivityAt: NOW - MINUTE }),
    ], { now: NOW, activeId: "b" });

    const current = all(host, "zf-room").filter((row) => row.getAttribute("aria-current") === "true");
    expect(current).toHaveLength(1);
    expect(current[0]?.getAttribute("data-room-id")).toBe("b");
  });

  it("explains an empty list in one sentence", () => {
    const host = root();
    renderRoomList(host as unknown as HTMLElement, [], { now: NOW, activeId: null });

    expect(count(host, "zf-room")).toBe(0);
    expect(one(host, "zf-empty").textContent).toBe(EMPTY_ROOMS);
  });

  it("opens a room when its row is clicked", () => {
    const host = root();
    const opened: string[] = [];
    renderRoomList(host as unknown as HTMLElement, [room({ id: "genel" })], {
      now: NOW,
      activeId: null,
      onSelect: (id) => opened.push(id),
    });

    one(host, "zf-room").fire("click");
    expect(opened).toEqual(["genel"]);
  });
});

describe("renderMessageStream", () => {
  it("draws the body and a mono clock, and nothing that identifies the writer", () => {
    const host = root();
    renderMessageStream(host as unknown as HTMLElement, [
      message({ body: "köprü kapalı mı", at: new Date(2026, 10, 22, 14, 3).getTime() }),
    ]);

    expect(one(host, "zf-msg-body").textContent).toBe("köprü kapalı mı");
    expect(one(host, "zf-msg-clock").textContent).toBe("14:03");
    expect(count(host, "zf-msg")).toBe(1);
    // No avatar slot, no name slot: the product has neither.
    expect(count(host, "zf-msg-avatar")).toBe(0);
    expect(count(host, "zf-msg-name")).toBe(0);
  });

  it("says why an empty room is empty", () => {
    const host = root();
    renderMessageStream(host as unknown as HTMLElement, []);

    expect(one(host, "zf-empty").textContent).toBe(EMPTY_MESSAGES);
  });
});

describe("composer", () => {
  it("starts in the default mode with the matching sentence", () => {
    const h = harness({ activeRoomId: "genel", rooms: [room()] });

    expect(DEFAULT_MODE).toBe("silent");
    expect(h.view.mode()).toBe("silent");
    expect(one(h.mount, "zf-consequence").textContent).toBe(describeMode("silent"));
    // The wait belongs to the queue line; the sentence states the privacy only,
    // so the two lines under the composer never say the same thing twice.
    expect(one(h.mount, "zf-consequence").textContent).not.toContain(SILENT_WAIT);
    expect(one(h.mount, "zf-pending").textContent).toContain(SILENT_WAIT);
    expect(radio(h.mount, "silent").checked).toBe(true);
    expect(radio(h.mount, "fast").checked).toBe(false);
  });

  it("changes the sentence when the mode changes", () => {
    const h = harness({ activeRoomId: "genel", rooms: [room()] });
    const silent = one(h.mount, "zf-consequence").textContent;

    radio(h.mount, "fast").checked = true;
    radio(h.mount, "fast").fire("change");

    const fast = one(h.mount, "zf-consequence").textContent;
    expect(h.view.mode()).toBe("fast");
    expect(fast).toBe(describeMode("fast"));
    expect(fast).toContain("hemen");
    expect(fast).not.toBe(silent);
  });

  it("shows the silent wait and the queue only in silent mode", () => {
    const h = harness({ activeRoomId: "genel", rooms: [room()], pending: 2 });

    const pending = one(h.mount, "zf-pending");
    expect(pending.hasAttribute("hidden")).toBe(false);
    expect(pending.textContent).toContain(SILENT_WAIT);
    expect(pending.textContent).toContain("2 bekliyor");

    h.view.setPending(0);
    expect(one(h.mount, "zf-pending").textContent).toContain("bekleyen yok");

    h.view.setMode("fast");
    expect(one(h.mount, "zf-pending").hasAttribute("hidden")).toBe(true);
  });

  it("counts characters against the limit", () => {
    const h = harness({ activeRoomId: "genel", rooms: [room()] });

    expect(one(h.mount, "zf-counter").textContent).toBe(`0 / ${CHAR_LIMIT}`);

    h.view.setValue("abc");
    expect(one(h.mount, "zf-counter").textContent).toBe(`3 / ${CHAR_LIMIT}`);
  });

  it("counts code points, not UTF-16 units", () => {
    const h = harness({ activeRoomId: "genel", rooms: [room()] });

    // Two emoji are two characters to the writer and four units to JavaScript.
    h.view.setValue("\u{1F600}\u{1F600}");
    expect("\u{1F600}\u{1F600}".length).toBe(4);
    expect(one(h.mount, "zf-counter").textContent).toBe(`2 / ${CHAR_LIMIT}`);
  });

  it("allows exactly the limit and blocks one character more", () => {
    const h = harness({ activeRoomId: "genel", rooms: [room()] });
    const send = one(h.mount, "zf-send");

    h.view.setValue("a".repeat(CHAR_LIMIT));
    expect(one(h.mount, "zf-counter").textContent).toBe(`${CHAR_LIMIT} / ${CHAR_LIMIT}`);
    expect(one(h.mount, "zf-counter").getAttribute("data-state")).toBe("ok");
    expect(send.hasAttribute("disabled")).toBe(false);

    h.view.setValue("a".repeat(CHAR_LIMIT + 1));
    expect(one(h.mount, "zf-counter").textContent).toContain("1 fazla");
    expect(one(h.mount, "zf-counter").getAttribute("data-state")).toBe("over");
    expect(send.hasAttribute("disabled")).toBe(true);
  });

  it("sends the body with the room and the mode, then clears the field", () => {
    const h = harness({ activeRoomId: "genel", rooms: [room()] });

    h.view.setValue("  köprü kapalı mı  ");
    h.view.form.fire("submit");

    expect(h.sent).toEqual([{ roomId: "genel", body: "köprü kapalı mı", mode: "silent" }]);
    expect(h.view.value()).toBe("");
    expect(one(h.mount, "zf-counter").textContent).toBe(`0 / ${CHAR_LIMIT}`);
  });

  it("sends in the mode that is on screen", () => {
    const h = harness({ activeRoomId: "genel", rooms: [room()] });

    h.view.setMode("fast");
    h.view.setValue("selam");
    h.view.send();

    expect(h.sent).toEqual([{ roomId: "genel", body: "selam", mode: "fast" }]);
  });

  it("refuses an empty draft", () => {
    const h = harness({ activeRoomId: "genel", rooms: [room()] });

    h.view.setValue("   ");
    h.view.form.fire("submit");

    expect(h.sent).toEqual([]);
    expect(one(h.mount, "zf-send").hasAttribute("disabled")).toBe(true);
  });

  it("refuses to send when no room is open", () => {
    const h = harness({ rooms: [room()] });

    h.view.setValue("selam");
    h.view.form.fire("submit");

    expect(h.sent).toEqual([]);
    expect(one(h.mount, "zf-composer").hasAttribute("hidden")).toBe(true);
    expect(one(h.mount, "zf-empty").textContent).toBe(NO_ROOM);
  });
});

describe("room selection", () => {
  it("opens a room and keeps the composer usable", () => {
    const h = harness({ rooms: [room({ id: "genel", name: "genel" })] });

    expect(one(h.mount, "zf-room-title").textContent).toBe("Oda seçilmedi");

    h.view.setRoom("genel");

    expect(one(h.mount, "zf-room-title").textContent).toBe("genel");
    expect(one(h.mount, "zf-room-sub").textContent).toBe("son mesaj şimdi");
    expect(one(h.mount, "zf-composer").hasAttribute("hidden")).toBe(false);

    h.view.setValue("selam");
    expect(one(h.mount, "zf-send").hasAttribute("disabled")).toBe(false);
  });

  it("reports a room click back to the caller", () => {
    const h = harness({ rooms: [room({ id: "genel" })] });

    one(h.mount, "zf-room").fire("click");

    expect(h.opened).toEqual(["genel"]);
  });

  it("draws messages for the open room", () => {
    const h = harness({
      activeRoomId: "genel",
      rooms: [room({ id: "genel" })],
      messages: [message({ body: "bir", at: NOW }), message({ id: "m2", body: "iki", at: NOW + 1000 })],
    });

    expect(all(h.mount, "zf-msg").map((row) => one(row, "zf-msg-body").textContent)).toEqual([
      "bir",
      "iki",
    ]);
  });
});
