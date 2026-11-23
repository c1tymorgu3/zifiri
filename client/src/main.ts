/**
 * zifiri — the client entry point.
 *
 * One page, three surfaces (Rooms / Messages / Listings), an identity panel and
 * a danger zone, exactly as the design lays them out. The shell draws the rail,
 * the top strip and the mobile tab bar; this file decides what each surface
 * shows and where its data comes from.
 *
 * Two data paths, one shape:
 *
 *  - live: `/api` on the same origin (rooms, listings) plus the in-memory
 *    identity. No third-party origin is ever contacted: no CDN, no font host,
 *    no analytics.
 *  - `?demo=1`: `src/demo/fixtures.ts`, loaded with `import()` only when the
 *    URL asks for it, so a production visitor never downloads a sample row.
 *    The badge in the top strip says "sample data" and carries `data-demo`.
 *
 * Every string is written with `textContent`. There is no `innerHTML` here and
 * none in the views. Nothing is stored: no `localStorage`, no cookie, no
 * `sessionStorage` — the identity, the draft and the mode live in this module's
 * variables and die with the tab.
 */
import "./app.css";

import { sha256 } from "@noble/hashes/sha2.js";
import { bytesToHex } from "@noble/hashes/utils.js";

import {
  ApiError,
  challenge,
  closeListing,
  createListing,
  decodeBody,
  fromB64,
  listListings,
  paddedBody,
  postRoomMessage,
  roomMessages,
} from "./api";
import { createIdentity, deriveIdentityKeys, deriveOwnToken, type Identity } from "./identity";
import { encode } from "./pad";
import { solve } from "./pow";
import { buildChatFrame, CHAT_POW_BITS, powDigest, signingInput } from "./room-send";
import { renderShell, type Shell, type SurfaceId } from "./shell";
import { createDmView, type DmView } from "./ui/dm-view";
import { createIdentityView, type IdentityView } from "./ui/identity-view";
import { createListingsView, type ListingsView } from "./ui/listings-view";
import { createRoomsView, type RoomMessage, type RoomsView, type RoomSummary } from "./ui/rooms-view";
import { renderNotice, renderOfflineRule, renderSkeleton } from "./ui/state-view";
import type { DmThread } from "./ui/dm";
import type { ListingItem, ListingValue } from "./ui/listings";
import type { Mode } from "./ui/mode";

/** scope v5, "two modes — fast by default": the product opens in fast. */
const START_MODE: Mode = "fast";

/** The only room the server keeps (`Zifiri.Chat.rooms/0`). */
const LIVE_ROOM: RoomSummary = {
  id: "chat:lobby",
  name: "lobby",
  lastActivityAt: 0,
  unread: 0,
  presence: false,
};

/**
 * Demo-only difficulty. The live path grinds `CHAT_POW_BITS` (12) and finishes
 * before the row is readable; the demo uses 20 so the progress line and its
 * cancel button are actually visible. Same code, same proof, bigger number.
 */
const DEMO_POW_BITS = 20;

interface DemoData {
  readonly rooms: readonly RoomSummary[];
  readonly messages: Readonly<Record<string, readonly RoomMessage[]>>;
  readonly threads: readonly DmThread[];
  readonly listings: readonly ListingItem[];
  readonly seed: Uint8Array;
  readonly nextI: number;
  readonly recent: number;
  readonly pending: number;
}

interface Host {
  readonly wrap: HTMLElement;
  readonly rule: HTMLElement;
  readonly status: HTMLElement;
  readonly state: HTMLElement;
  readonly view: HTMLElement;
}

function el<K extends keyof HTMLElementTagNameMap>(
  doc: Document,
  tag: K,
  className: string,
  text?: string,
): HTMLElementTagNameMap[K] {
  const node = doc.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function makeHost(doc: Document): Host {
  const wrap = el(doc, "div", "zf-panel");
  const rule = el(doc, "div", "zf-offline");
  rule.setAttribute("role", "status");
  rule.hidden = true;
  const status = el(doc, "p", "zf-status");
  status.setAttribute("role", "status");
  status.setAttribute("aria-live", "polite");
  const state = el(doc, "div", "zf-state-slot");
  state.hidden = true;
  const view = el(doc, "div", "zf-view-slot");
  wrap.append(rule, status, state, view);
  return { wrap, rule, status, state, view };
}

function loading(host: Host, rows: number): void {
  host.state.hidden = false;
  host.view.hidden = true;
  renderSkeleton(host.state, rows);
}

function ready(host: Host): void {
  host.state.hidden = true;
  host.state.replaceChildren();
  host.view.hidden = false;
}

function notice(host: Host, title: string, body: string, action?: { label: string; run: () => void }): void {
  host.state.hidden = false;
  host.view.hidden = true;
  renderNotice(host.state, action === undefined ? { title, body } : { title, body, action });
}

function say(host: Host, text: string): void {
  host.status.textContent = text;
}

function describe(error: unknown): string {
  if (error instanceof Error && error.name === "AbortError") return "Cancelled.";
  if (error instanceof ApiError) return `The server said ${error.status} (${error.code}).`;
  return "The server could not be reached.";
}

async function loadDemo(): Promise<DemoData> {
  const fixtures = await import("./demo/fixtures");
  return {
    rooms: fixtures.demoRooms,
    messages: fixtures.demoMessages,
    threads: fixtures.demoThreads,
    listings: fixtures.demoListings,
    seed: fixtures.DEMO_SEED,
    nextI: fixtures.DEMO_NEXT_I,
    recent: fixtures.demoRecentCount,
    pending: fixtures.demoPendingCount,
  };
}

async function boot(): Promise<void> {
  const root = document.getElementById("app");
  if (root === null) return;

  const doc = root.ownerDocument;
  const params = new URLSearchParams(window.location.search);
  const demo = params.get("demo") === "1" ? await loadDemo() : null;

  // `?surface=messages` opens a surface directly. It is a link, not state: the
  // client still stores nothing, and an unknown value falls back to Rooms.
  const wanted = params.get("surface");
  const initial: SurfaceId =
    wanted === "messages" || wanted === "listings" || wanted === "rooms" ? wanted : "rooms";
  const identity: Identity =
    demo === null
      ? createIdentity()
      : { seed: demo.seed, nextI: demo.nextI, generation: 0 };

  const hosts: Record<SurfaceId, Host> = {
    rooms: makeHost(doc),
    messages: makeHost(doc),
    listings: makeHost(doc),
  };
  const identityHost = makeHost(doc);
  identityHost.view.className = "zf-view-slot zf-identity-slot";

  const shell: Shell = renderShell(root, {
    active: initial,
    badge: demo === null ? null : "sample data",
    onNavigate: (id) => show(id),
    onIdentity: () => show("identity"),
    identity: null,
  });

  // The badge belongs to the shell; `data-demo` is this module's promise that
  // every row on screen came from fixtures.
  if (demo !== null) shell.topbar.querySelector(".zf-badge")?.setAttribute("data-demo", "true");

  function show(target: SurfaceId | "identity"): void {
    if (target === "identity") {
      shell.setContent(identityHost.wrap);
      return;
    }
    shell.setActive(target);
    shell.setContent(hosts[target].wrap);
  }

  /* -- rooms -------------------------------------------------------------- */

  const roomMessagesById = new Map<string, RoomMessage[]>();
  let pendingCount = demo?.pending ?? 0;
  let cancelPow: AbortController | null = null;

  const roomsView: RoomsView = createRoomsView({
    mount: hosts.rooms.view,
    mode: START_MODE,
    anonymity: demo?.recent ?? 1,
    pending: pendingCount,
    onCancel: () => {
      cancelPow?.abort();
    },
    onSend: ({ roomId, body, mode }) => {
      void sendRoom(roomId, body, mode);
    },
  });

  function applyRooms(
    rooms: readonly RoomSummary[],
    messages: Readonly<Record<string, readonly RoomMessage[]>>,
  ): void {
    roomMessagesById.clear();
    for (const [id, list] of Object.entries(messages)) roomMessagesById.set(id, [...list]);
    roomsView.setRooms(rooms);
    const first = rooms[0];
    if (first !== undefined) {
      roomsView.setRoom(first.id);
      roomsView.setMessages(roomMessagesById.get(first.id) ?? []);
    }
    ready(hosts.rooms);
  }

  async function loadRooms(): Promise<void> {
    loading(hosts.rooms, 4);
    try {
      if (demo !== null) {
        applyRooms(demo.rooms, demo.messages);
        return;
      }
      const page = await roomMessages(LIVE_ROOM.id);
      const decoder = new TextDecoder();
      const list: RoomMessage[] = page.messages.map((message) => ({
        id: String(message.id),
        body: decoder.decode(decodeBody(fromB64(message.body))),
        at: Date.now(),
      }));
      const room: RoomSummary = {
        ...LIVE_ROOM,
        lastActivityAt: list.length === 0 ? 0 : Date.now(),
      };
      applyRooms([room], { [room.id]: list });
    } catch (error) {
      notice(hosts.rooms, "Rooms did not open", describe(error), {
        label: "try again",
        run: () => void loadRooms(),
      });
    }
  }

  async function sendRoom(roomId: string, body: string, mode: Mode): Promise<void> {
    if (!navigator.onLine) {
      roomsView.setValue(body);
      say(hosts.rooms, "No connection. Writing is off; try again when it returns.");
      return;
    }

    const controller = new AbortController();
    cancelPow = controller;
    roomsView.setSending(true);
    roomsView.setPow(0);

    try {
      if (demo !== null) {
        const digest = powDigest(new TextEncoder().encode(`${roomId}\u0000${body}`));
        await solve(digest, DEMO_POW_BITS, {
          signal: controller.signal,
          onProgress: (attempts) => roomsView.setPow(attempts),
        });
        const list = roomMessagesById.get(roomId) ?? [];
        list.push({ id: `demo-${Date.now()}`, body, at: Date.now() });
        roomMessagesById.set(roomId, list);
        roomsView.setMessages(list);
        if (mode === "silent") {
          pendingCount += 1;
          roomsView.setPending(pendingCount);
        }
        say(hosts.rooms, mode === "silent" ? "Queued; it publishes within 10 minutes." : "Sent.");
        return;
      }

      const page = await roomMessages(roomId);
      const raw = new TextEncoder().encode(body);
      const padded = encode(raw);
      const keys = deriveIdentityKeys(identity.seed);
      const ctr = (page.last_ctr[bytesToHex(keys.publicKey)] ?? 0) + 1;
      const digest = powDigest(signingInput(roomId, page.epoch, ctr, padded));
      const nonce = await solve(digest, CHAT_POW_BITS, {
        signal: controller.signal,
        onProgress: (attempts) => roomsView.setPow(attempts),
      });
      const frame = buildChatFrame({ seed: identity.seed, room: roomId, epoch: page.epoch, ctr, body: raw, padded });
      await postRoomMessage(roomId, { ...frame, ctr, nonce });
      say(hosts.rooms, "Sent.");
      await loadRooms();
    } catch (error) {
      roomsView.setValue(body);
      say(hosts.rooms, describe(error));
    } finally {
      cancelPow = null;
      roomsView.setPow(null);
      roomsView.setSending(false);
    }
  }

  /* -- messages ----------------------------------------------------------- */

  const threads: DmThread[] =
    demo === null ? [] : demo.threads.map((thread) => ({ ...thread, messages: [...thread.messages] }));

  const dmView: DmView = createDmView({
    mount: hosts.messages.view,
    mode: START_MODE === "fast" ? "fast" : "silent",
    presenceEnabled: demo !== null,
    onSend: (peer, text, mode) => {
      if (demo === null) throw new Error("1:1 transport is not wired in this build");
      const thread = threads.find((candidate) => candidate.peer === peer);
      if (thread === undefined) throw new Error("conversation not found");
      thread.messages.push({ id: `dm-${Date.now()}`, peer, text, at: Date.now(), self: true, unread: false });
      thread.lastText = text;
      thread.lastAt = Date.now();
      dmView.setThreads(threads);
      say(hosts.messages, mode === "silent" ? "Queued; it publishes within 10 minutes." : "Sent.");
    },
  });

  function loadMessages(): void {
    if (demo === null) {
      notice(
        hosts.messages,
        "No conversations",
        "1:1 messaging needs an identity and an envelope transport; neither is wired in this build. Rooms are open.",
        { label: "go to rooms", run: () => show("rooms") },
      );
      return;
    }
    dmView.setLoading(false);
    dmView.setThreads(threads);
    ready(hosts.messages);
    void dmView.select(threads[0]?.peer ?? null);
  }

  /* -- listings ----------------------------------------------------------- */

  let listings: ListingItem[] = demo === null ? [] : [...demo.listings];

  const listingsView: ListingsView = createListingsView(hosts.listings.view, {
    onPublish: (value) => {
      void publishListing(value);
    },
    onMessage: () => {
      say(hosts.listings, "Messaging the owner needs a conversation first.");
    },
    onClose: (item) => {
      void removeListing(item);
    },
  });

  async function loadListings(): Promise<void> {
    loading(hosts.listings, 5);
    try {
      if (demo !== null) {
        listingsView.setItems(listings);
        ready(hosts.listings);
        return;
      }
      const rows = await listListings({ limit: 50 });
      listings = rows.map((row) => ({
        id: String(row.ref),
        title: row.title,
        body: new TextDecoder().decode(decodeBody(fromB64(row.body_b64))),
        price: row.price_cents,
        currency: row.currency,
        category: row.category,
        day: row.day ?? "",
      }));
      listingsView.setItems(listings);
      ready(hosts.listings);
    } catch (error) {
      notice(hosts.listings, "Listings did not open", describe(error), {
        label: "try again",
        run: () => void loadListings(),
      });
    }
  }

  async function publishListing(value: ListingValue): Promise<void> {
    if (demo !== null) {
      listings = [
        {
          id: `demo-${Date.now()}`,
          title: value.title,
          body: value.body,
          price: value.price,
          currency: "TRY",
          category: value.category,
          day: new Date().toISOString().slice(0, 10),
        },
        ...listings,
      ];
      listingsView.setItems(listings);
      listingsView.showList();
      say(hosts.listings, "Listing is live.");
      return;
    }

    try {
      const ownerToken = deriveOwnToken(identity.seed, identity.nextI);
      // The server's proof covers the padded envelope, so the hash is taken
      // over exactly the bytes that will be sent.
      const payloadHash = sha256(paddedBody(value.body));
      const ticket = await challenge(ownerToken, payloadHash);
      say(hosts.listings, "Computing proof…");
      const nonce = await solve(payloadHash, ticket.bits);
      await createListing({
        title: value.title,
        body: value.body,
        category: value.category,
        ownerToken,
        challengeId: ticket.id,
        nonce,
        bits: ticket.bits,
        priceCents: value.price,
      });
      say(hosts.listings, "Listing is live.");
      await loadListings();
      listingsView.showList();
    } catch (error) {
      say(hosts.listings, describe(error));
    }
  }

  async function removeListing(item: ListingItem): Promise<void> {
    if (demo !== null) {
      listings = listings.filter((row) => row.id !== item.id);
      listingsView.setItems(listings);
      listingsView.showList();
      say(hosts.listings, "Listing closed.");
      return;
    }
    try {
      await closeListing(item.id, deriveOwnToken(identity.seed, identity.nextI));
      say(hosts.listings, "Listing closed.");
      await loadListings();
      listingsView.showList();
    } catch (error) {
      say(hosts.listings, describe(error));
    }
  }

  /* -- identity ----------------------------------------------------------- */

  const identityView: IdentityView = createIdentityView({
    mount: identityHost.view,
    onVanish: () => {
      shell.setIdentity(null);
      roomsView.setRooms([]);
      roomsView.setMessages([]);
      dmView.clear();
      listingsView.setItems([]);
      say(hosts.rooms, "Identity deleted. Reload the page for a new one.");
      show("rooms");
    },
  });

  identityView.show(identity.seed, identity.nextI);
  const fingerprint = identityView.fingerprint();
  if (fingerprint !== null) shell.setIdentity({ fingerprint });

  const identityHead = el(doc, "div", "zf-identity-head");
  const close = el(doc, "button", "zf-identity-close", "close");
  close.type = "button";
  close.addEventListener("click", () => show("rooms"));
  identityHead.append(close);
  identityHost.view.prepend(identityHead);

  /* -- offline ------------------------------------------------------------ */

  const paintOffline = (): void => {
    const offline = !navigator.onLine;
    for (const host of Object.values(hosts)) renderOfflineRule(host.rule, offline);
    renderOfflineRule(identityHost.rule, offline);
  };
  window.addEventListener("online", paintOffline);
  window.addEventListener("offline", paintOffline);

  /* -- first paint -------------------------------------------------------- */

  show(initial);
  paintOffline();
  void loadRooms();
  loadMessages();
  void loadListings();
}

void boot();
