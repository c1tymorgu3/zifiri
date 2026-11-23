/**
 * Rooms: the write path and the list, with the mode switch wired in.
 *
 * Fast mode posts the envelope as soon as it is sealed and padded. Silent mode
 * parks it in an in-memory queue and posts it when the current 10-minute bucket
 * closes, so the write time an observer sees is the bucket boundary and not the
 * moment the writer pressed "send".
 *
 * Three deliberate constraints:
 *
 *  - `pad` is required and its output must be exactly a padding bucket. An
 *    unpadded body is a body whose length is the message, so a missing or lying
 *    pad is a refusal, never a fallback to raw bytes.
 *  - The clock is injected. The queue's whole behaviour is time, so the tests
 *    drive time instead of sleeping; the browser passes the system clock.
 *  - Nothing here reads `localStorage` or writes a draft anywhere. A queued
 *    message lives in this module's memory and dies with the tab.
 *
 * Decoys are rendered by the same function as real messages and carry no
 * marker: an interface that says "this one is filler" tells the reader which
 * one is not.
 */

import { PAD_BUCKETS } from "../pad";
import { DEFAULT_MODE, isMode, type Mode } from "./mode";

/** Silent-mode bucket: ten minutes, aligned to the epoch. */
export const BUCKET_MS = 10 * 60 * 1000;

/** Decoy target from scope v5: every published bucket holds 120 messages. */
export const BUCKET_SIZE = 120;

export type MessageStatus = "draft" | "waiting" | "sent" | "failed";

export type RoomErrorCode =
  | "empty"
  | "bad_mode"
  | "pad_required"
  | "bad_padding"
  | "no_document";

export class RoomError extends Error {
  override name = "RoomError";

  constructor(
    message: string,
    readonly code: RoomErrorCode,
  ) {
    super(message);
  }
}

/** Seals plaintext; may be async because real sealing uses the room key. */
export type SealFn = (body: Uint8Array) => Uint8Array | Promise<Uint8Array>;

/** Pads to a fixed bucket; must return one of `PAD_BUCKETS`. */
export type PadFn = (body: Uint8Array) => Uint8Array;

/** Solves the proof over the padded envelope and returns the nonce. */
export type PowFn = (envelope: Uint8Array) => number | Promise<number>;

/** What actually leaves the browser. No room key, no author, no timestamp. */
export interface OutgoingMessage {
  id: string;
  room: string;
  envelope: Uint8Array;
  nonce: number | null;
  mode: Mode;
}

export type PostFn = (message: OutgoingMessage) => Promise<unknown>;

export type TimerHandle = unknown;

export interface Clock {
  now(): number;
  setTimeout(callback: () => void, ms: number): TimerHandle;
  clearTimeout(handle: TimerHandle): void;
}

export interface SendRequest {
  room: string;
  body: string;
  mode: Mode;
  pad: PadFn;
  post: PostFn;
  seal?: SealFn;
  pow?: PowFn;
  /** Injected in tests; the page passes nothing and gets the system clock. */
  clock?: Clock;
}

export interface SendResult {
  id: string;
  status: MessageStatus;
  error: string | null;
}

interface Entry {
  id: string;
  room: string;
  mode: Mode;
  status: MessageStatus;
  envelope: Uint8Array;
  nonce: number | null;
  post: PostFn;
  pow: PowFn | null;
  flushAt: number;
  error: string | null;
}

const systemClock: Clock = {
  now: () => Date.now(),
  setTimeout: (callback, ms) => setTimeout(callback, ms),
  clearTimeout: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
};

/** The end of the bucket `now` falls in; a message at a boundary waits a full one. */
export function bucketEnd(now: number): number {
  return (Math.floor(now / BUCKET_MS) + 1) * BUCKET_MS;
}

function messageOf(caught: unknown): string {
  if (caught instanceof Error && caught.message !== "") return caught.message;
  return "could not be sent";
}

export class Outbox {
  private readonly entries = new Map<string, Entry>();
  private queue: string[] = [];
  private timer: TimerHandle | null = null;
  private nextId = 1;
  private clock: Clock;

  constructor(clock: Clock = systemClock) {
    this.clock = clock;
  }

  async send(request: SendRequest): Promise<SendResult> {
    if (request.clock) this.clock = request.clock;

    if (!isMode(request.mode)) {
      throw new RoomError(`unknown mode: ${String(request.mode)}`, "bad_mode");
    }
    if (request.body.trim() === "") {
      throw new RoomError("an empty message is not sent", "empty");
    }
    if (typeof request.pad !== "function") {
      throw new RoomError("pad required: an unpadded body is not sent", "pad_required");
    }

    const plain = new TextEncoder().encode(request.body);
    const sealed = request.seal ? await request.seal(plain) : plain;
    const envelope = request.pad(sealed);

    if (!(envelope instanceof Uint8Array)) {
      throw new RoomError("pad must return a Uint8Array", "bad_padding");
    }
    if (!(PAD_BUCKETS as readonly number[]).includes(envelope.length)) {
      throw new RoomError(
        `padding ${envelope.length} bytes; bucket sizes: ${PAD_BUCKETS.join(", ")}`,
        "bad_padding",
      );
    }

    const id = `m${this.nextId++}`;
    const entry: Entry = {
      id,
      room: request.room,
      mode: request.mode,
      status: "draft",
      envelope,
      nonce: null,
      post: request.post,
      pow: request.pow ?? null,
      flushAt: 0,
      error: null,
    };
    this.entries.set(id, entry);

    if (request.mode === "fast") {
      return this.deliver(entry);
    }

    entry.status = "waiting";
    entry.flushAt = bucketEnd(this.clock.now());
    this.queue.push(id);
    this.schedule(entry.flushAt);

    return { id, status: "waiting", error: null };
  }

  /** Waiting messages only; sent and failed ones are history, not a backlog. */
  pendingCount(): number {
    let count = 0;
    for (const entry of this.entries.values()) {
      if (entry.status === "waiting") count += 1;
    }
    return count;
  }

  statusOf(id: string): MessageStatus | null {
    return this.entries.get(id)?.status ?? null;
  }

  /**
   * Drops a waiting message. Returns false for anything already on its way: a
   * post that has left cannot be recalled by deleting a row in this map.
   */
  cancel(id: string): boolean {
    const entry = this.entries.get(id);
    if (!entry || entry.status !== "waiting") return false;
    this.queue = this.queue.filter((queued) => queued !== id);
    this.entries.delete(id);
    if (this.queue.length === 0) this.clearTimer();
    return true;
  }

  /** Test hook: forgets the queue and any pending timer. */
  reset(): void {
    this.clearTimer();
    this.entries.clear();
    this.queue = [];
    this.nextId = 1;
    this.clock = systemClock;
  }

  private clearTimer(): void {
    if (this.timer === null) return;
    this.clock.clearTimeout(this.timer);
    this.timer = null;
  }

  private schedule(at: number): void {
    if (this.timer !== null) return;
    const delay = Math.max(0, at - this.clock.now());
    this.timer = this.clock.setTimeout(() => {
      this.timer = null;
      void this.flush();
    }, delay);
  }

  private async flush(): Promise<void> {
    const due = this.queue;
    this.queue = [];

    for (const id of due) {
      const entry = this.entries.get(id);
      if (!entry || entry.status !== "waiting") continue;
      await this.deliver(entry);
    }

    const [next] = this.queue;
    if (next !== undefined) {
      const entry = this.entries.get(next);
      if (entry) this.schedule(entry.flushAt);
    }
  }

  private async deliver(entry: Entry): Promise<SendResult> {
    try {
      if (entry.pow) entry.nonce = await entry.pow(entry.envelope);
      await entry.post({
        id: entry.id,
        room: entry.room,
        envelope: entry.envelope,
        nonce: entry.nonce,
        mode: entry.mode,
      });
      entry.status = "sent";
      return { id: entry.id, status: "sent", error: null };
    } catch (caught) {
      entry.status = "failed";
      entry.error = messageOf(caught);
      return { id: entry.id, status: "failed", error: entry.error };
    }
  }
}

const outbox = new Outbox();

/** One message through the outbox; the mode decides whether it waits. */
export function sendMessage(request: SendRequest): Promise<SendResult> {
  return outbox.send(request);
}

/** Waiting messages, for the badge next to the mode switch. */
export function pendingCount(): number {
  return outbox.pendingCount();
}

export function statusOf(id: string): MessageStatus | null {
  return outbox.statusOf(id);
}

export function cancelPending(id: string): boolean {
  return outbox.cancel(id);
}

/** Test hook; the page never calls this. */
export function resetRooms(): void {
  outbox.reset();
}

export interface RoomMessage {
  id: string;
  room: string;
  body: string;
  /** Locally known to be ours; the server never supplies this. */
  self?: boolean;
  /**
   * Present so a caller can hand over decoys unchanged. The renderer must not
   * read it: marking a decoy marks the real message next to it.
   */
  decoy?: boolean;
}

/**
 * Renders rooms and their messages. Everything goes in through `textContent`;
 * there is no `innerHTML` in this file, and the CSP has nothing to block.
 *
 * No timestamps are rendered either. The only timing the system keeps is the
 * bucket, and a rendered clock would hand back the precision the bucket removed.
 */
export function renderRooms(root: HTMLElement, messages: readonly RoomMessage[]): void {
  const doc = root.ownerDocument ?? (typeof document === "undefined" ? null : document);
  if (doc === null) throw new RoomError("renderRooms requires a document", "no_document");

  root.replaceChildren();

  if (messages.length === 0) {
    const empty = doc.createElement("p");
    empty.className = "empty";
    empty.textContent = "No messages yet.";
    root.append(empty);
    return;
  }

  const groups = new Map<string, RoomMessage[]>();
  for (const message of messages) {
    const existing = groups.get(message.room);
    if (existing) existing.push(message);
    else groups.set(message.room, [message]);
  }

  for (const [room, items] of groups) {
    const section = doc.createElement("section");
    section.className = "room";

    const heading = doc.createElement("h2");
    heading.textContent = room;
    section.append(heading);

    const list = doc.createElement("ul");
    for (const message of items) {
      const item = doc.createElement("li");
      item.className = message.self ? "message self" : "message";

      const body = doc.createElement("span");
      body.className = "body";
      body.textContent = message.body;

      item.append(body);
      list.append(item);
    }

    section.append(list);
    root.append(section);
  }
}
