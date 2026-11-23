import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { decode as padDecode, encode as padEncode, type PadBucket } from "../src/pad";
import {
  BUCKET_MS,
  RoomError,
  bucketEnd,
  cancelPending,
  pendingCount,
  renderRooms,
  resetRooms,
  sendMessage,
  statusOf,
  type Clock,
  type OutgoingMessage,
  type PadFn,
  type PostFn,
  type RoomMessage,
  type SealFn,
  type SendRequest,
} from "../src/ui/rooms";

const encoder = new TextEncoder();

const START = Date.UTC(2026, 10, 22, 12, 0, 0);

function padTo(bucket: PadBucket = 4096): PadFn {
  return (body) => padEncode(body, bucket);
}

interface Recorder {
  post: PostFn;
  posts: OutgoingMessage[];
  mock: ReturnType<typeof vi.fn>;
}

function recorder(): Recorder {
  const posts: OutgoingMessage[] = [];
  const mock = vi.fn(async (message: OutgoingMessage) => {
    posts.push(message);
    return { ok: true };
  });
  return { post: mock as unknown as PostFn, posts, mock };
}

interface SendOptions {
  post: PostFn;
  mode?: "fast" | "silent";
  body?: string;
  pad?: PadFn;
  seal?: SealFn;
  pow?: (envelope: Uint8Array) => number | Promise<number>;
  clock?: Clock;
}

function send(options: SendOptions): ReturnType<typeof sendMessage> {
  const request: SendRequest = {
    room: "genel",
    body: options.body ?? "merhaba",
    mode: options.mode ?? "silent",
    pad: options.pad ?? padTo(),
    post: options.post,
  };
  if (options.seal) request.seal = options.seal;
  if (options.pow) request.pow = options.pow;
  if (options.clock) request.clock = options.clock;
  return sendMessage(request);
}

beforeEach(() => {
  resetRooms();
  vi.useFakeTimers();
  vi.setSystemTime(START);
});

afterEach(() => {
  resetRooms();
  vi.useRealTimers();
});

describe("fast mode", () => {
  it("posts at once and reports sent", async () => {
    const { post, posts, mock } = recorder();

    const result = await send({ mode: "fast", post });

    expect(result).toEqual({ id: "m1", status: "sent", error: null });
    expect(mock).toHaveBeenCalledTimes(1);
    expect(posts).toHaveLength(1);
    expect(posts[0]?.mode).toBe("fast");
    expect(posts[0]?.room).toBe("genel");
    expect(posts[0]?.envelope.length).toBe(4096);
    expect(pendingCount()).toBe(0);
    expect(statusOf("m1")).toBe("sent");
  });

  it("is a draft while the post is still in flight", async () => {
    const gate: { release: (() => void) | null } = { release: null };
    const post: PostFn = () =>
      new Promise<void>((resolve) => {
        gate.release = resolve;
      });

    const pending = send({ mode: "fast", post });
    expect(statusOf("m1")).toBe("draft");

    gate.release?.();
    const result = await pending;
    expect(result.status).toBe("sent");
    expect(statusOf("m1")).toBe("sent");
  });

  it("turns a rejected post into failed, not a lost message", async () => {
    const post: PostFn = async () => {
      throw new Error("ağ yok");
    };

    const result = await send({ mode: "fast", post });

    expect(result.status).toBe("failed");
    expect(result.error).toBe("ağ yok");
    expect(statusOf("m1")).toBe("failed");
  });
});

describe("silent mode", () => {
  it("waits for the bucket instead of posting", async () => {
    const { post, mock } = recorder();

    const result = await send({ mode: "silent", post });

    expect(result).toEqual({ id: "m1", status: "waiting", error: null });
    expect(mock).not.toHaveBeenCalled();
    expect(pendingCount()).toBe(1);
    expect(statusOf("m1")).toBe("waiting");
  });

  it("posts exactly at the ten-minute boundary, not one tick earlier", async () => {
    const { post, mock } = recorder();
    await send({ mode: "silent", post });

    await vi.advanceTimersByTimeAsync(BUCKET_MS - 1);
    expect(mock).not.toHaveBeenCalled();
    expect(pendingCount()).toBe(1);

    await vi.advanceTimersByTimeAsync(1);
    expect(mock).toHaveBeenCalledTimes(1);
    expect(pendingCount()).toBe(0);
    expect(statusOf("m1")).toBe("sent");
  });

  it("flushes at the end of the current bucket, not ten minutes after the write", async () => {
    // Three minutes into a bucket, so seven minutes remain.
    vi.setSystemTime(START + 3 * 60 * 1000);
    const { post, mock } = recorder();
    await send({ mode: "silent", post });

    await vi.advanceTimersByTimeAsync(7 * 60 * 1000 - 1);
    expect(mock).not.toHaveBeenCalled();

    await vi.advanceTimersByTimeAsync(1);
    expect(mock).toHaveBeenCalledTimes(1);
    expect(bucketEnd(START + 3 * 60 * 1000)).toBe(START + BUCKET_MS);
  });

  it("sends one bucket's messages together, in order", async () => {
    const { post, posts } = recorder();
    await send({ mode: "silent", body: "bir", post });
    await send({ mode: "silent", body: "iki", post });
    expect(pendingCount()).toBe(2);

    await vi.advanceTimersByTimeAsync(BUCKET_MS);

    expect(posts.map((message) => message.id)).toEqual(["m1", "m2"]);
    expect(pendingCount()).toBe(0);
  });

  it("keeps a message that arrives after the flush for the next bucket", async () => {
    const { post, mock } = recorder();
    await send({ mode: "silent", post });
    await vi.advanceTimersByTimeAsync(BUCKET_MS);
    expect(mock).toHaveBeenCalledTimes(1);

    await send({ mode: "silent", post });
    expect(pendingCount()).toBe(1);
    await vi.advanceTimersByTimeAsync(BUCKET_MS - 1);
    expect(mock).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(mock).toHaveBeenCalledTimes(2);
  });

  it("marks a failed flush as failed and clears the backlog", async () => {
    const post: PostFn = async () => {
      throw new Error("sunucu kapalı");
    };
    await send({ mode: "silent", post });

    await vi.advanceTimersByTimeAsync(BUCKET_MS);

    expect(statusOf("m1")).toBe("failed");
    expect(pendingCount()).toBe(0);
  });
});

describe("cancelling a waiting message", () => {
  it("drops it from the queue and never posts it", async () => {
    const { post, mock } = recorder();
    await send({ mode: "silent", post });

    expect(cancelPending("m1")).toBe(true);
    expect(pendingCount()).toBe(0);
    expect(statusOf("m1")).toBeNull();

    await vi.advanceTimersByTimeAsync(BUCKET_MS * 2);
    expect(mock).not.toHaveBeenCalled();
  });

  it("refuses to cancel something already sent", async () => {
    const { post } = recorder();
    await send({ mode: "fast", post });

    expect(cancelPending("m1")).toBe(false);
    expect(statusOf("m1")).toBe("sent");
  });
});

describe("padding is mandatory", () => {
  it("refuses to send without a pad function", async () => {
    const { post, mock } = recorder();
    const request = {
      room: "genel",
      body: "merhaba",
      mode: "fast",
      post,
    } as unknown as SendRequest;

    await expect(sendMessage(request)).rejects.toBeInstanceOf(RoomError);
    await expect(sendMessage(request)).rejects.toMatchObject({ code: "pad_required" });
    expect(mock).not.toHaveBeenCalled();
  });

  it("refuses a pad that returns something that is not a bucket", async () => {
    const { post, mock } = recorder();

    await expect(send({ mode: "fast", post, pad: () => new Uint8Array(300) })).rejects.toMatchObject({
      code: "bad_padding",
    });
    await expect(send({ mode: "fast", post, pad: () => "x" as unknown as Uint8Array })).rejects.toMatchObject({
      code: "bad_padding",
    });
    expect(mock).not.toHaveBeenCalled();
  });

  it("refuses an empty body before anything is sealed", async () => {
    const { post, mock } = recorder();
    const seal = vi.fn((body: Uint8Array) => body);

    await expect(send({ mode: "fast", post, body: "   ", seal })).rejects.toMatchObject({ code: "empty" });
    expect(seal).not.toHaveBeenCalled();
    expect(mock).not.toHaveBeenCalled();
  });

  it("refuses an unknown mode instead of guessing", async () => {
    const { post } = recorder();
    const request = {
      room: "genel",
      body: "merhaba",
      mode: "turbo",
      pad: padTo(),
      post,
    } as unknown as SendRequest;

    await expect(sendMessage(request)).rejects.toMatchObject({ code: "bad_mode" });
  });
});

describe("seal and proof", () => {
  it("seals the plaintext first and pads the ciphertext", async () => {
    const { post, posts } = recorder();
    const sealed = new Uint8Array([1, 2, 3, 4, 5]);
    const seal = vi.fn((_body: Uint8Array): Uint8Array => sealed);
    const pad = vi.fn((body: Uint8Array) => padEncode(body, 256));

    await send({ mode: "fast", post, body: "gizli", seal, pad });

    expect(seal).toHaveBeenCalledTimes(1);
    expect(seal.mock.calls[0]?.[0]).toEqual(encoder.encode("gizli"));
    expect(pad).toHaveBeenCalledTimes(1);
    expect(pad.mock.calls[0]?.[0]).toEqual(sealed);

    const envelope = posts[0]?.envelope;
    expect(envelope?.length).toBe(256);
    expect(padDecode(envelope as Uint8Array)).toEqual(sealed);
  });

  it("solves the proof only when the bucket closes", async () => {
    const { post, posts } = recorder();
    const pow = vi.fn((_envelope: Uint8Array) => 7);

    await send({ mode: "silent", post, pow });
    expect(pow).not.toHaveBeenCalled();

    await vi.advanceTimersByTimeAsync(BUCKET_MS);

    expect(pow).toHaveBeenCalledTimes(1);
    expect(pow.mock.calls[0]?.[0]).toEqual(posts[0]?.envelope);
    expect(posts[0]?.nonce).toBe(7);
  });

  it("works with an injected clock, so time is a parameter", async () => {
    vi.useRealTimers();

    let now = START;
    let seq = 0;
    const timers = new Map<number, { at: number; run: () => void }>();
    const clock: Clock = {
      now: () => now,
      setTimeout: (run, ms) => {
        const handle = ++seq;
        timers.set(handle, { at: now + ms, run });
        return handle;
      },
      clearTimeout: (handle) => {
        timers.delete(handle as number);
      },
    };

    const advance = (ms: number): void => {
      const target = now + ms;
      for (;;) {
        const due = [...timers.entries()]
          .filter(([, timer]) => timer.at <= target)
          .sort((a, b) => a[1].at - b[1].at)[0];
        if (due === undefined) break;
        timers.delete(due[0]);
        now = due[1].at;
        due[1].run();
      }
      now = target;
    };

    const { post, posts } = recorder();
    await send({ mode: "silent", post, clock });
    expect(pendingCount()).toBe(1);

    advance(9 * 60 * 1000);
    expect(posts).toHaveLength(0);

    advance(60 * 1000);
    await vi.waitFor(() => expect(posts).toHaveLength(1));
    expect(posts[0]?.id).toBe("m1");
  });
});

// --- render ---------------------------------------------------------------

class FakeElement {
  readonly tagName: string;
  readonly children: FakeElement[] = [];
  textContent = "";
  className = "";
  private nodes: FakeElement[] = [];

  constructor(tagName: string) {
    this.tagName = tagName;
  }

  append(...nodes: FakeElement[]): void {
    this.nodes.push(...nodes);
  }

  replaceChildren(...nodes: FakeElement[]): void {
    this.nodes.splice(0, this.nodes.length, ...nodes);
  }

  get innerHTML(): string {
    throw new Error("innerHTML yasak: renderRooms textContent kullanmalı");
  }

  set innerHTML(_value: string) {
    throw new Error("innerHTML yasak: renderRooms textContent kullanmalı");
  }

  get childNodes(): readonly FakeElement[] {
    return this.nodes;
  }
}

const fakeDocument = {
  createElement: (tagName: string) => new FakeElement(tagName),
} as unknown as Document;

function mount(): { root: HTMLElement; node: FakeElement } {
  const node = new FakeElement("div");
  (node as unknown as { ownerDocument: Document }).ownerDocument = fakeDocument;
  return { root: node as unknown as HTMLElement, node };
}

function serialize(node: FakeElement): string {
  const children = node.childNodes.map(serialize).join("");
  const inner = children === "" ? node.textContent : children;
  return `<${node.tagName} class="${node.className}">${inner}</${node.tagName}>`;
}

describe("renderRooms", () => {
  it("groups by room and keeps the message text as text", () => {
    const { root, node } = mount();
    const hostile = '<img src=x onerror="alert(1)">';

    renderRooms(root, [
      { id: "a", room: "genel", body: "selam" },
      { id: "b", room: "genel", body: hostile, self: true },
      { id: "c", room: "pazar", body: "ikinci oda" },
    ]);

    const html = serialize(node);
    expect(html).toContain("<h2 class=\"\">genel</h2>");
    expect(html).toContain("<h2 class=\"\">pazar</h2>");
    // The markup is shown, not parsed: the only escaping that matters is this one.
    expect(html).toContain(hostile);
    expect(html).toContain('class="message self"');
    expect(html).toContain('class="message"');
  });

  it("renders decoys exactly like real messages: no marker, no class, no text", () => {
    const real: RoomMessage = { id: "a", room: "genel", body: "selam" };
    const decoy: RoomMessage = { id: "b", room: "genel", body: "selam", decoy: true };

    const plain = mount();
    renderRooms(plain.root, [real]);

    const withDecoy = mount();
    renderRooms(withDecoy.root, [{ ...real, decoy: true }]);

    expect(serialize(withDecoy.node)).toBe(serialize(plain.node));
    expect(serialize(withDecoy.node)).not.toMatch(/decoy|sahte|dolgu/i);

    // And a decoy in a mixed list is a plain message next to a plain message.
    const mixed = mount();
    renderRooms(mixed.root, [real, decoy]);
    const mirror = mount();
    renderRooms(mirror.root, [real, { ...real }]);

    expect(serialize(mixed.node)).toBe(serialize(mirror.node));
    const section = mixed.node.childNodes[0];
    expect(section?.childNodes[1]?.childNodes).toHaveLength(2);
  });

  it("says the room is empty instead of inventing a message", () => {
    const { root, node } = mount();
    renderRooms(root, []);

    expect(node.childNodes).toHaveLength(1);
    expect(serialize(node)).toContain("Henüz mesaj yok.");
  });

  it("replaces the previous render rather than appending to it", () => {
    const { root, node } = mount();
    renderRooms(root, [{ id: "a", room: "genel", body: "bir" }]);
    renderRooms(root, [{ id: "b", room: "genel", body: "iki" }]);

    const html = serialize(node);
    expect(html).toContain("iki");
    expect(html).not.toContain("bir");
    expect(node.childNodes).toHaveLength(1);
  });
});
