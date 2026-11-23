/**
 * 1:1 messaging surface (scope v5, "1:1 — there is no sender").
 *
 * The server keeps a mailbox keyed by `HMAC(pepper, recipient_pk)` and no
 * sender column at all, so this module owns everything the wire does not say:
 *
 *  - a conversation list keyed by peer public key, built only from envelopes
 *    that actually decrypted;
 *  - a pull cursor (`since`) so a client never re-reads a bucket it already
 *    drained, and never asks the server "what is new for me" in a way that
 *    would need an identity;
 *  - decoys. A bucket is filled to 120 with envelopes the recipient has no key
 *    for, so "cannot open" is the normal case, not an error. `open` returning
 *    `null` and `open` throwing are the same thing here: one decoy, skipped;
 *  - presence, coarse and mutual, and off by default. When it is off this
 *    module must not touch the network — the test asserts the request function
 *    is never called, because a disabled switch that still pings is a lie.
 *
 * Rendering uses `textContent` only, and identifies a peer by a short base32
 * fingerprint rather than by a key blob: a 64-character hex string in a chat
 * list is unreadable, and a "name" would be a claim the protocol cannot back.
 */
import { sha256 } from "@noble/hashes/sha2.js";
import { bytesToHex } from "@noble/hashes/utils.js";

const BASE32_ALPHABET = "abcdefghijklmnopqrstuvwxyz234567";
const FINGERPRINT_BYTES = 8;
const FINGERPRINT_LENGTH = 13;
const MAX_SUMMARY = 64;
const SEEN_LIMIT = 4096;

/** Presence is coarse on purpose: "now" or "not now", five-minute grain. */
export const PRESENCE_WINDOW_MS = 5 * 60 * 1000;

export type PresenceLabel = "online" | "5+ min" | "unknown";

export type PeerKey = Uint8Array;

/** What a successfully opened envelope yields. `from` is the sender's pk, hex. */
export interface OpenedMessage {
  /** Sender public key, 64 hex characters (or any stable peer id). */
  from: string;
  text: string;
  /** Optional author timestamp, ms since epoch. */
  at?: number;
}

export type SealFn = (peer: PeerKey, text: string) => Uint8Array | Promise<Uint8Array>;
export type OpenFn = (
  body: Uint8Array,
) => OpenedMessage | null | Promise<OpenedMessage | null>;
export type DeliverFn = (body: Uint8Array) => unknown;
export type FetchMailboxFn = (since: string | null) => MailboxPage | Promise<MailboxPage>;
export type PresenceFn = (
  peer: PeerKey,
) => PresenceReading | null | Promise<PresenceReading | null>;

/** One row from the mailbox. `expiresAt` is the server TTL, ms since epoch. */
export interface MailboxEnvelope {
  id: string;
  body: Uint8Array;
  expiresAt?: number;
}

export interface MailboxPage {
  envelopes: readonly MailboxEnvelope[];
  /** Cursor to hand back on the next pull. */
  since: string | null;
}

export interface PresenceReading {
  /** Last time the peer was seen, ms since epoch. */
  lastSeen: number;
}

export interface DmMessage {
  id: string;
  /** Peer id this message belongs to (hex pk when known). */
  peer: string;
  text: string;
  at: number;
  self: boolean;
  unread: boolean;
}

export interface DmThread {
  /** Peer id: hex public key, or whatever `open` reported. */
  peer: string;
  /** Raw pk when the peer id parses as one. */
  peerKey: Uint8Array | null;
  messages: DmMessage[];
  /** Last message text, capped for display. */
  lastText: string;
  lastAt: number;
  /** Unread, openable messages only. */
  unread: number;
  presence: PresenceLabel;
}

export interface DmPullResult {
  opened: number;
  /** Envelopes that would not open: decoys, corrupt bodies. Never an error. */
  skipped: number;
  /** Envelopes past their TTL; dropped without an open attempt. */
  expired: number;
  duplicates: number;
  threads: DmThread[];
}

export interface DmDeps {
  seal: SealFn;
  open: OpenFn;
  deliver: DeliverFn;
  fetchMailbox: FetchMailboxFn;
  /** Injected so tests can count calls; absent means presence is unavailable. */
  presence?: PresenceFn;
  /** Injected clock, ms since epoch. */
  now?: () => number;
}

export interface Dm {
  /** Conversation list, newest first. */
  threads(): DmThread[];
  /** Seal, deliver, and show the message locally as sent. */
  send(peer: PeerKey, text: string): Promise<DmMessage>;
  /** Drain the mailbox from the current cursor. */
  pull(): Promise<DmPullResult>;
  /** Clear the unread flag on one conversation. */
  markRead(peer: string | PeerKey): void;
  /** Presence label, and no request at all when `enabled` is false. */
  presenceState(peer: PeerKey, enabled: boolean): Promise<PresenceLabel>;
  cursor(): string | null;
}

export class DmError extends Error {
  override name = "DmError";
}

/** base32(sha256(pk)[0..8]): 13 lowercase characters, same shape as an identity fingerprint. */
export function peerFingerprint(publicKey: Uint8Array): string {
  if (!(publicKey instanceof Uint8Array) || publicKey.length === 0) {
    throw new DmError("peer key must be a non-empty Uint8Array");
  }
  return base32(sha256(publicKey).slice(0, FINGERPRINT_BYTES));
}

/** Groups a fingerprint for reading aloud: `abcd-efgh-ijklm`. */
export function formatPeerFingerprint(fingerprint: string): string {
  if (fingerprint.length !== FINGERPRINT_LENGTH) return fingerprint;
  return `${fingerprint.slice(0, 4)}-${fingerprint.slice(4, 8)}-${fingerprint.slice(8)}`;
}

/** Human label for a thread: fingerprint when the key is known, short id otherwise. */
export function peerLabel(thread: DmThread): string {
  if (thread.peerKey !== null && thread.peerKey.length > 0) {
    return formatPeerFingerprint(peerFingerprint(thread.peerKey));
  }
  const bytes = hexToBytes(thread.peer);
  if (bytes !== null) return formatPeerFingerprint(peerFingerprint(bytes));
  return thread.peer.slice(0, 8) || "unknown";
}

/** One-line summary of a message for the conversation list. */
export function summarize(text: string, max = MAX_SUMMARY): string {
  const flat = text.replace(/\s+/g, " ").trim();
  if (flat.length <= max) return flat;
  return `${flat.slice(0, Math.max(0, max - 1))}…`;
}

/**
 * Presence, coarse and mutual. Off means off: with `enabled` not strictly true
 * this returns "unknown" before touching the injected request function, so
 * a disabled switch leaves no row, no ping, no timing signal.
 */
export async function presenceState(
  peer: PeerKey,
  enabled: boolean,
  request?: PresenceFn,
  now: () => number = Date.now,
): Promise<PresenceLabel> {
  if (enabled !== true) return "unknown";
  if (request === undefined) return "unknown";

  let reading: PresenceReading | null = null;
  try {
    reading = await request(peer);
  } catch {
    // A presence probe that fails is not a reason to show a peer as online,
    // and it is not a reason to break the conversation list either.
    return "unknown";
  }
  if (reading === null || typeof reading !== "object") return "unknown";
  const lastSeen = reading.lastSeen;
  if (typeof lastSeen !== "number" || !Number.isFinite(lastSeen)) return "unknown";
  return now() - lastSeen <= PRESENCE_WINDOW_MS ? "online" : "5+ min";
}

/** Only openable envelopes are ever counted; decoys never reach a thread. */
export function unreadCount(threads: readonly DmThread[]): number {
  let total = 0;
  for (const thread of threads) {
    const value = thread.unread;
    if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) continue;
    total += Math.trunc(value);
  }
  return total;
}

export function createDm(deps: DmDeps): Dm {
  if (typeof deps.seal !== "function") throw new DmError("seal is required");
  if (typeof deps.open !== "function") throw new DmError("open is required");
  if (typeof deps.deliver !== "function") throw new DmError("deliver is required");
  if (typeof deps.fetchMailbox !== "function") throw new DmError("fetchMailbox is required");

  const clock = deps.now ?? Date.now;
  const threads = new Map<string, DmThread>();
  const seen = new Set<string>();
  const seenOrder: string[] = [];
  let since: string | null = null;
  let outgoing = 0;

  function threadFor(peer: string, peerKey: Uint8Array | null): DmThread {
    const existing = threads.get(peer);
    if (existing !== undefined) {
      if (existing.peerKey === null && peerKey !== null) existing.peerKey = peerKey;
      return existing;
    }
    const created: DmThread = {
      peer,
      peerKey,
      messages: [],
      lastText: "",
      lastAt: 0,
      unread: 0,
      presence: "unknown",
    };
    threads.set(peer, created);
    return created;
  }

  function append(thread: DmThread, message: DmMessage): void {
    thread.messages.push(message);
    thread.lastText = summarize(message.text);
    if (message.at >= thread.lastAt) thread.lastAt = message.at;
    if (message.unread && !message.self) thread.unread += 1;
  }

  function remember(id: string): void {
    seen.add(id);
    seenOrder.push(id);
    while (seenOrder.length > SEEN_LIMIT) {
      const oldest = seenOrder.shift();
      if (oldest !== undefined) seen.delete(oldest);
    }
  }

  function listThreads(): DmThread[] {
    return [...threads.values()]
      .slice()
      .sort((a, b) => b.lastAt - a.lastAt)
      .map((thread) => ({
        ...thread,
        messages: thread.messages.slice(),
        peerKey: thread.peerKey === null ? null : thread.peerKey.slice(),
      }));
  }

  return {
    threads: listThreads,

    async send(peer, text) {
      if (!(peer instanceof Uint8Array) || peer.length === 0) {
        throw new DmError("peer key must be a non-empty Uint8Array");
      }
      if (typeof text !== "string" || text.trim() === "") {
        throw new DmError("message text must not be empty");
      }
      const body = await deps.seal(peer, text);
      if (!(body instanceof Uint8Array) || body.length === 0) {
        throw new DmError("seal produced no envelope body");
      }
      await deps.deliver(body);

      const peerHex = bytesToHex(peer);
      const message: DmMessage = {
        id: `out:${outgoing++}`,
        peer: peerHex,
        text,
        at: clock(),
        self: true,
        unread: false,
      };
      append(threadFor(peerHex, peer.slice()), message);
      return message;
    },

    async pull() {
      const page = await deps.fetchMailbox(since);
      const envelopes = Array.isArray(page?.envelopes) ? page.envelopes : [];
      const now = clock();
      let opened = 0;
      let skipped = 0;
      let expired = 0;
      let duplicates = 0;

      for (const envelope of envelopes) {
        if (!envelope || typeof envelope.id !== "string" || envelope.id === "") {
          skipped += 1;
          continue;
        }
        if (seen.has(envelope.id)) {
          duplicates += 1;
          continue;
        }
        remember(envelope.id);

        if (typeof envelope.expiresAt === "number" && envelope.expiresAt <= now) {
          expired += 1;
          continue;
        }
        if (!(envelope.body instanceof Uint8Array)) {
          skipped += 1;
          continue;
        }

        let message: OpenedMessage | null = null;
        try {
          message = await deps.open(envelope.body);
        } catch {
          // No key for this envelope: a decoy, or a corrupt body. Same handling.
          message = null;
        }
        if (
          message === null ||
          typeof message !== "object" ||
          typeof message.text !== "string" ||
          typeof message.from !== "string" ||
          message.from.trim() === ""
        ) {
          skipped += 1;
          continue;
        }

        const from = message.from.trim().toLowerCase();
        const peerKey = hexToBytes(from);
        const at = typeof message.at === "number" && Number.isFinite(message.at) ? message.at : now;
        append(threadFor(from, peerKey), {
          id: `in:${envelope.id}`,
          peer: from,
          text: message.text,
          at,
          self: false,
          unread: true,
        });
        opened += 1;
      }

      if (typeof page?.since === "string" && page.since !== "") since = page.since;
      return { opened, skipped, expired, duplicates, threads: listThreads() };
    },

    markRead(peer) {
      const key = typeof peer === "string" ? peer.trim().toLowerCase() : bytesToHex(peer);
      const thread = threads.get(key);
      if (thread === undefined) return;
      for (const message of thread.messages) message.unread = false;
      thread.unread = 0;
    },

    async presenceState(peer, enabled) {
      const label = await presenceState(peer, enabled, deps.presence, clock);
      const thread = threads.get(bytesToHex(peer));
      if (thread !== undefined) thread.presence = label;
      return label;
    },

    cursor() {
      return since;
    },
  };
}

/**
 * Conversation list. Text in, text out: no `innerHTML`, no peer-supplied tag
 * names, no markup path at all.
 */
export function renderDm(root: HTMLElement, threads: readonly DmThread[]): void {
  const doc = root.ownerDocument;

  if (threads.length === 0) {
    const empty = doc.createElement("p");
    empty.className = "empty";
    empty.textContent = "You have not talked to anyone yet.";
    root.replaceChildren(empty);
    return;
  }

  const list = doc.createElement("ul");
  list.className = "dm-threads";

  for (const thread of threads) {
    const item = doc.createElement("li");
    const button = doc.createElement("button");
    button.type = "button";
    button.className = "dm-thread";
    button.dataset.peer = thread.peer;

    const peer = doc.createElement("span");
    peer.className = "dm-peer";
    peer.textContent = peerLabel(thread);

    const preview = doc.createElement("span");
    preview.className = "dm-preview";
    preview.textContent = thread.lastText === "" ? "no messages" : summarize(thread.lastText);

    const presence = doc.createElement("span");
    presence.className = "dm-presence";
    presence.textContent = thread.presence;

    button.append(peer, preview, presence);

    if (thread.unread > 0) {
      const badge = doc.createElement("span");
      badge.className = "dm-unread";
      badge.textContent = `${thread.unread} unread`;
      button.append(badge);
    }

    item.append(button);
    list.append(item);
  }

  root.replaceChildren(list);
}

function hexToBytes(hex: string): Uint8Array | null {
  if (hex.length !== 64 || !/^[0-9a-f]+$/.test(hex)) return null;
  const out = new Uint8Array(32);
  for (let i = 0; i < 32; i += 1) out[i] = Number.parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  return out;
}

function base32(bytes: Uint8Array): string {
  let out = "";
  let bits = 0;
  let value = 0;
  for (const byte of bytes) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      out += BASE32_ALPHABET[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
    value &= (1 << bits) - 1;
  }
  if (bits > 0) out += BASE32_ALPHABET[(value << (5 - bits)) & 31];
  return out;
}
