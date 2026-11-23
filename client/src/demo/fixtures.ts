/**
 * Sample data for `?demo=1`.
 *
 * Two rules hold this file together:
 *
 *  1. It is loaded through `import()` only when the URL says `demo=1`, so a
 *     production visitor downloads none of it and the live path never reads a
 *     single value from here.
 *  2. It is shaped exactly like the live data (RoomSummary, DmThread,
 *     ListingItem, an identity seed). The views cannot tell demo from real,
 *     which is the point: what you see in the screenshot is the same code the
 *     server path runs.
 *
 * The copy is ordinary on purpose: neighbourhood notices, a second-hand sale,
 * an evening job. Nothing here claims an anonymity guarantee; that claim lives
 * in the composer, once.
 */
import type { DmMessage, DmThread } from "../ui/dm";
import type { ListingItem } from "../ui/listings";
import type { RoomMessage, RoomSummary } from "../ui/rooms-view";

const MINUTE = 60_000;

/** A fixed instant, so two screenshots of the demo are the same picture. */
const NOW = Date.UTC(2026, 10, 23, 6, 40);

/** 32 bytes, stable across reloads. Demo only; never a real identity. */
export const DEMO_SEED = Uint8Array.from([
  0x7a, 0x1f, 0x04, 0xc3, 0x9b, 0x22, 0x5d, 0xe8, 0x31, 0x0a, 0x6c, 0xb7, 0x48, 0x95, 0x0e, 0xd2,
  0x53, 0x8a, 0xf1, 0x26, 0xbc, 0x67, 0x19, 0x80, 0x4e, 0xd5, 0x3b, 0x91, 0xaa, 0x02, 0x7f, 0xc6,
]);

export const DEMO_NEXT_I = 7;

export const demoRooms: readonly RoomSummary[] = [
  {
    id: "lobby",
    name: "lobby",
    lastActivityAt: NOW - 2 * MINUTE,
    unread: 3,
    presence: true,
  },
  {
    id: "neighbourhood",
    name: "neighbourhood",
    lastActivityAt: NOW - 26 * MINUTE,
    unread: 0,
    presence: true,
  },
  {
    id: "market",
    name: "market",
    lastActivityAt: NOW - 3 * 60 * MINUTE,
    unread: 0,
    presence: false,
  },
];

export const demoMessages: Readonly<Record<string, readonly RoomMessage[]>> = {
  lobby: [
    { id: "l1", body: "bridge is jammed at this hour, the ferry is faster", at: NOW - 41 * MINUTE },
    { id: "l2", body: "someone left a bike unlocked by the pier", at: NOW - 33 * MINUTE },
    { id: "l3", body: "no lock usually means the owner is close", at: NOW - 28 * MINUTE },
    { id: "l4", body: "I'll put something on the board tonight, have a look", at: NOW - 12 * MINUTE },
    { id: "l5", body: "nobody asks your name here, it takes a while to get used to", at: NOW - 5 * MINUTE },
    { id: "l6", body: "the market room has a listing with no price: trade only", at: NOW - 2 * MINUTE },
  ],
  neighbourhood: [
    { id: "m1", body: "the water is off upstairs, they say until 2pm", at: NOW - 3 * 60 * MINUTE },
    { id: "m2", body: "stair light is out again, someone fix it tonight", at: NOW - 2 * 60 * MINUTE },
    { id: "m3", body: "done, I had a bulb", at: NOW - 26 * MINUTE },
  ],
  market: [
    { id: "p1", body: "those two chairs still there? listing was up yesterday", at: NOW - 8 * 60 * MINUTE },
    { id: "p2", body: "still here, both wood, one leg is scratched", at: NOW - 7 * 60 * MINUTE },
    { id: "p3", body: "I'll come by this evening, same place?", at: NOW - 3 * 60 * MINUTE },
  ],
};

function message(id: string, peer: string, text: string, minutesAgo: number, self: boolean): DmMessage {
  return {
    id,
    peer,
    text,
    at: NOW - minutesAgo * MINUTE,
    self,
    unread: false,
  };
}

const PEER_ONE = "9f2c4b7e1a8d6350c4e9b2a7d1f8063b5c7e9a1d2f4b6c8e0a3d5f7b9c1e3a5d";
const PEER_TWO = "3c1d5f7b9a2e4c6d8f0a1b3c5d7e9f1a2b4c6d8e0f1a3b5c7d9e1f2a4b6c8d0e";

export const demoThreads: readonly DmThread[] = [
  {
    peer: PEER_ONE,
    peerKey: null,
    messages: [
      message("t1", PEER_ONE, "is the monitor listing still up", 58, false),
      message("t2", PEER_ONE, "it is, 24 inch, two dead pixels bottom right", 54, true),
      message("t3", PEER_ONE, "can I see it saturday", 51, false),
      message("t4", PEER_ONE, "sure, meet by the pier", 48, true),
    ],
    lastText: "sure, meet by the pier",
    lastAt: NOW - 48 * MINUTE,
    unread: 0,
    presence: "online",
  },
  {
    peer: PEER_TWO,
    peerKey: null,
    messages: [
      message("t5", PEER_TWO, "are the chairs in your listing still available", 130, false),
      message("t6", PEER_TWO, "they are, two of them", 126, true),
      message("t7", PEER_TWO, "you didn't put a price", 121, false),
      message("t8", PEER_TWO, "trade, whatever you have", 118, true),
    ],
    lastText: "trade, whatever you have",
    lastAt: NOW - 118 * MINUTE,
    unread: 1,
    presence: "5+ min",
  },
];

export const demoListings: readonly ListingItem[] = [
  {
    id: "1043",
    title: "blue",
    body: "one side scratched, works fine. pick up in the evening.",
    price: 320000,
    currency: "TRY",
    category: "transport",
    day: "2026-11-21",
  },
  {
    id: "1042",
    title: "green",
    body: "unused, box opened once. trade or cash.",
    price: null,
    currency: "TRY",
    category: "clothing",
    day: "2026-11-20",
  },
  {
    id: "1041",
    title: "red",
    body: "small mark on the back, otherwise clean.",
    price: 45000,
    currency: "TRY",
    category: "home",
    day: "2026-11-19",
  },
  {
    id: "1040",
    title: "purple",
    body: "two of them, both working. no delivery.",
    price: 180000,
    currency: "TRY",
    category: "home",
    day: "2026-11-18",
  },
  {
    id: "1039",
    title: "amber",
    body: "older model, still does the job.",
    price: 145000,
    currency: "TRY",
    category: "electronics",
    day: "2026-11-17",
  },
  {
    id: "1038",
    title: "grey",
    body: "pick up only, weekdays after six.",
    price: 1200000,
    currency: "TRY",
    category: "work",
    day: "2026-11-16",
  },
];

/** How many messages the last minute carried; the composer's honest number. */
export const demoRecentCount = 4;

/** Silent-mode queue, as the demo shows it: two waiting in the bucket. */
export const demoPendingCount = 2;
