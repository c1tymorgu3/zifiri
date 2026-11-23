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
    id: "lobi",
    name: "lobi",
    lastActivityAt: NOW - 2 * MINUTE,
    unread: 3,
    presence: true,
  },
  {
    id: "mahalle",
    name: "mahalle",
    lastActivityAt: NOW - 26 * MINUTE,
    unread: 0,
    presence: true,
  },
  {
    id: "pazar",
    name: "pazar",
    lastActivityAt: NOW - 3 * 60 * MINUTE,
    unread: 0,
    presence: false,
  },
];

export const demoMessages: Readonly<Record<string, readonly RoomMessage[]>> = {
  lobi: [
    { id: "l1", body: "köprü bu saatte kilit, metrobüs daha hızlı", at: NOW - 41 * MINUTE },
    { id: "l2", body: "kadıköy iskelesinde bir bisiklet bırakılmış, kilidi yok", at: NOW - 33 * MINUTE },
    { id: "l3", body: "kilit yoksa sahibi yakındadır, acele etme", at: NOW - 28 * MINUTE },
    { id: "l4", body: "akşam ilan panosuna bir şey asacağım, göz atın", at: NOW - 12 * MINUTE },
    { id: "l5", body: "burada kimse adını sormuyor, alışana kadar tuhaf geliyor", at: NOW - 5 * MINUTE },
    { id: "l6", body: "alım satım odasında bir ilan var, fiyat yazmıyor: takas", at: NOW - 2 * MINUTE },
  ],
  mahalle: [
    { id: "m1", body: "üst katın suyu kesilmiş, saat 14'e kadar sürer diyorlar", at: NOW - 3 * 60 * MINUTE },
    { id: "m2", body: "merdiven lambası yine sönmüş, akşam biri değiştirsin", at: NOW - 2 * 60 * MINUTE },
    { id: "m3", body: "değiştirdim, ampul bende vardı", at: NOW - 26 * MINUTE },
  ],
  pazar: [
    { id: "p1", body: "iki sandalye hâlâ duruyor mu, dün ilan vardı", at: NOW - 8 * 60 * MINUTE },
    { id: "p2", body: "duruyor, ikisi de ahşap, birinin ayağı çizik", at: NOW - 7 * 60 * MINUTE },
    { id: "p3", body: "akşam üstü bakmaya geleceğim, yer aynı mı", at: NOW - 3 * 60 * MINUTE },
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
      message("t1", PEER_ONE, "monitör ilanı hâlâ geçerli mi", 58, false),
      message("t2", PEER_ONE, "geçerli, 24 inç, iki ölü piksel var sağ altta", 54, true),
      message("t3", PEER_ONE, "cumartesi bakabilir miyim", 51, false),
      message("t4", PEER_ONE, "olur, iskele tarafında buluşuruz", 48, true),
    ],
    lastText: "olur, iskele tarafında buluşuruz",
    lastAt: NOW - 48 * MINUTE,
    unread: 0,
    presence: "çevrimiçi",
  },
  {
    peer: PEER_TWO,
    peerKey: null,
    messages: [
      message("t5", PEER_TWO, "ilanındaki sandalyeler hâlâ duruyor mu", 130, false),
      message("t6", PEER_TWO, "duruyor, iki tane", 126, true),
      message("t7", PEER_TWO, "fiyat yazmamışsın", 121, false),
      message("t8", PEER_TWO, "takas; karşılığında ne olursa", 118, true),
    ],
    lastText: "takas; karşılığında ne olursa",
    lastAt: NOW - 118 * MINUTE,
    unread: 1,
    presence: "5+ dk",
  },
];

export const demoListings: readonly ListingItem[] = [
  {
    id: "1041",
    title: "Monitör, 24 inç, 75 Hz",
    body:
      "Sağ altta iki ölü piksel var, normal kullanımda görünmüyor. Ayağı ve kablosu dahil. " +
      "Kadıköy, hafta içi akşam bakılabilir.",
    price: 145000,
    currency: "TRY",
    category: "elektronik",
    day: "2026-11-21",
  },
  {
    id: "1040",
    title: "İki ahşap sandalye",
    body: "Birinin ayağı çizik, ikisi de sağlam. Takas olur, nakit de olur.",
    price: 90000,
    currency: "TRY",
    category: "ev",
    day: "2026-11-20",
  },
  {
    id: "1039",
    title: "Bisiklet, 28 jant",
    body: "Frenleri yeni değişti. Zincir biraz sesli. Kilidi yok, alırken getir.",
    price: 320000,
    currency: "TRY",
    category: "arac",
    day: "2026-11-19",
  },
  {
    id: "1038",
    title: "Akşamları dükkân açma yardımı",
    body:
      "Haftada üç akşam, dört saat. Kasa değil, raf ve sayım işi. Kim olduğun sorulmaz; " +
      "işi yapabildiğin sorulur.",
    price: 120000,
    currency: "TRY",
    category: "is",
    day: "2026-11-18",
  },
  {
    id: "1037",
    title: "Mont, kalın, L beden",
    body: "İki kış giyildi, astarı sağlam. Beden olmuyor, takas tercih edilir.",
    price: null,
    currency: "TRY",
    category: "giyim",
    day: "2026-11-16",
  },
  {
    id: "1036",
    title: "Su tesisatı, küçük işler",
    body: "Musluk, gider, rezervuar. Malzeme sende, işçilik bende. Akşamüstü uygun.",
    price: 45000,
    currency: "TRY",
    category: "hizmet",
    day: "2026-11-15",
  },
];

/** How many messages the last minute carried; the composer's honest number. */
export const demoRecentCount = 4;

/** Silent-mode queue, as the demo shows it: two waiting in the bucket. */
export const demoPendingCount = 2;
