import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  ApiError,
  ackMailbox,
  challenge,
  closeListing,
  createListing,
  decodeBody,
  deliverEnvelope,
  erase,
  fetchMailbox,
  fromB64,
  getListing,
  listListings,
  MAILBOX_ENVELOPE_BYTES,
  postRoomMessage,
  roomMessages,
  toB64,
  toB64Url,
} from "../src/api";
import { PadError } from "../src/pad";

const TOKEN = new Uint8Array(32).fill(7);
const TOKEN_B64 = toB64(TOKEN);
const PK = new Uint8Array(32).fill(9);

const fetchMock = vi.fn();

beforeEach(() => {
  fetchMock.mockReset();
  vi.stubGlobal("fetch", fetchMock);
});

afterEach(() => {
  vi.unstubAllGlobals();
});

/** The server pads every answer to 16384 bytes with spaces. */
function reply(payload: unknown, status = 200): void {
  const body = JSON.stringify(payload) + " ".repeat(512);
  fetchMock.mockResolvedValueOnce(
    new Response(body, { status, headers: { "content-type": "application/json" } }),
  );
}

function call(index = 0): { url: string; init: RequestInit; headers: Record<string, string> } {
  const [url, init] = fetchMock.mock.calls[index] as [string, RequestInit];
  return { url, init, headers: (init.headers ?? {}) as Record<string, string> };
}

describe("challenge", () => {
  it("binds the challenge to the owner header and the payload hash, not the URL", async () => {
    reply({ id: "ch-1", bits: 18 });

    const result = await challenge(TOKEN, new Uint8Array(32).fill(1));

    const { url, init, headers } = call();
    expect(url).toBe(`/api/pow?payload_hash=${toB64Url(new Uint8Array(32).fill(1))}`);
    expect(url).not.toContain(TOKEN_B64);
    expect(init.method).toBe("GET");
    expect(headers["x-zifiri-owner"]).toBe(TOKEN_B64);
    expect(result).toEqual({ id: "ch-1", bits: 18 });
  });

  it("refuses a payload hash that is not 32 bytes before touching the network", async () => {
    await expect(challenge(TOKEN, new Uint8Array(16))).rejects.toThrow(TypeError);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("maps a server refusal to an ApiError with its code", async () => {
    reply({ error: "refused" }, 403);

    await expect(challenge(TOKEN, new Uint8Array(32))).rejects.toMatchObject({
      name: "ApiError",
      status: 403,
      code: "refused",
    });
  });
});

describe("listings", () => {
  const input = {
    title: "Bicycle",
    body: "Clean, used for two years.",
    category: "transport",
    ownerToken: TOKEN,
    challengeId: "ch-1",
    nonce: 4242,
    bits: 18,
  };

  it("creates a listing with a padded envelope and the token only in the header", async () => {
    reply({ status: "created", ref: 12 }, 201);

    const created = await createListing({ ...input, priceCents: 150000, currency: "USD" });

    const { url, init, headers } = call();
    expect(url).toBe("/api/listings");
    expect(init.method).toBe("POST");
    expect(headers["x-zifiri-owner"]).toBe(TOKEN_B64);
    expect(headers["content-type"]).toBe("application/json");

    const body = JSON.parse(String(init.body)) as Record<string, unknown>;
    expect(body.owner_token).toBeUndefined();
    expect(body.owner).toBeUndefined();
    expect(body.token).toBeUndefined();
    expect(body.title).toBe("Bicycle");
    expect(body.price_cents).toBe(150000);
    expect(body.currency).toBe("USD");
    expect(body.category).toBe("transport");
    expect(body.challenge_id).toBe("ch-1");
    expect(body.nonce).toBe(4242);
    expect(body.bits).toBe(18);

    const envelope = fromB64(String(body.envelope));
    expect(envelope.length).toBe(256);
    expect(new TextDecoder().decode(decodeBody(envelope))).toBe(input.body);
    expect(created).toEqual({ status: "created", ref: 12 });
  });

  it("honours an explicit bucket for a long description", async () => {
    reply({ status: "created", ref: 13 }, 201);
    const body = "x".repeat(3000);

    await createListing({ ...input, body, bucket: 4096 });

    const sent = JSON.parse(String(call().init.body)) as Record<string, unknown>;
    expect(fromB64(String(sent.envelope)).length).toBe(4096);
  });

  it("lists with q, category, before and limit — never a token", async () => {
    reply({ listings: [] });

    await listListings({ q: "bicycle", category: "transport", before: 99, limit: 20 });

    const { url, headers } = call();
    const [path, query] = url.split("?");
    expect(path).toBe("/api/listings");
    const params = new URLSearchParams(query);
    expect(params.get("q")).toBe("bicycle");
    expect(params.get("category")).toBe("transport");
    expect(params.get("before")).toBe("99");
    expect(params.get("limit")).toBe("20");
    expect(url).not.toContain(TOKEN_B64);
    expect(headers["x-zifiri-owner"]).toBeUndefined();
  });

  it("lists without a query string when no filters are given", async () => {
    reply({ listings: [] });

    await listListings();

    expect(call().url).toBe("/api/listings");
  });

  it("fetches one listing and unwraps it", async () => {
    const listing = {
      ref: 5,
      title: "Table",
      price_cents: 90000,
      currency: "USD",
      category: "ev",
      day: "2026-11-22",
      body_b64: toB64(new Uint8Array([1, 2, 3])),
    };
    reply({ listing });

    await expect(getListing(5)).resolves.toEqual(listing);
    expect(call().url).toBe("/api/listings/5");
  });

  it("maps a missing listing to not_found", async () => {
    reply({ error: "not_found" }, 404);

    await expect(getListing(404)).rejects.toMatchObject({
      status: 404,
      code: "not_found",
    });
  });

  it("closes with DELETE and the token header, and sends no body", async () => {
    reply({ status: "deleted" });

    await closeListing(12, TOKEN);

    const { url, init, headers } = call();
    expect(url).toBe("/api/listings/12");
    expect(init.method).toBe("DELETE");
    expect(init.body).toBeUndefined();
    expect(headers["x-zifiri-owner"]).toBe(TOKEN_B64);
    expect(url).not.toContain(TOKEN_B64);
  });
});

describe("mailbox", () => {
  const envelope = new Uint8Array(MAILBOX_ENVELOPE_BYTES).fill(3);

  it("delivers a 4096-byte envelope to the recipient tag", async () => {
    reply({ status: "accepted" }, 202);

    await deliverEnvelope(PK, envelope);

    const { url, init, headers } = call();
    expect(url.startsWith("/api/mailbox/")).toBe(true);
    expect(decodeURIComponent(url.slice("/api/mailbox/".length))).toBe(toB64(PK));
    expect(init.method).toBe("POST");
    expect(headers["x-zifiri-owner"]).toBeUndefined();
    const body = JSON.parse(String(init.body)) as Record<string, unknown>;
    expect(fromB64(String(body.envelope)).length).toBe(MAILBOX_ENVELOPE_BYTES);
  });

  it("refuses a short envelope locally instead of sending it", async () => {
    await expect(deliverEnvelope(PK, new Uint8Array(100))).rejects.toBeInstanceOf(PadError);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("fetches the mailbox from a cursor and normalises a sparse page", async () => {
    reply({ messages: [{ id: 2, envelope_b64: "AAAA" }], cursor: 2 });

    const page = await fetchMailbox(PK, 1);

    const { url } = call();
    expect(url.startsWith("/api/mailbox/")).toBe(true);
    expect(url.endsWith("?since=1")).toBe(true);
    expect(page).toEqual({
      messages: [{ id: 2, envelope_b64: "AAAA" }],
      cursor: 2,
      more: false,
    });
  });

  it("acknowledges ids for one recipient in the body", async () => {
    reply({ status: "acked" });

    await ackMailbox(PK, [4, 5]);

    const { url, init } = call();
    expect(url).toBe("/api/mailbox/ack");
    expect(init.method).toBe("POST");
    expect(JSON.parse(String(init.body))).toEqual({
      recipient_pk: toB64(PK),
      ids: [4, 5],
    });
  });
});

describe("rooms", () => {
  it("reads a room from a cursor", async () => {
    reply({ epoch: "e1", last_ctr: { pk: 3 }, messages: [] });

    const page = await roomMessages("lobby", 3);

    expect(call().url).toBe("/api/rooms/lobby?since=3");
    expect(page).toEqual({ epoch: "e1", last_ctr: { pk: 3 }, messages: [] });
  });

  it("posts a message with url-safe base64 fields", async () => {
    reply({ status: "accepted", ref: 1, epoch: "e1" }, 202);
    const body = new TextEncoder().encode("hello");
    const pubkey = new Uint8Array(32).fill(1);
    const sig = new Uint8Array(64).fill(2);

    await postRoomMessage("lobby", { body, pubkey, sig, ctr: 7, nonce: 11 });

    const { url, init } = call();
    expect(url).toBe("/api/rooms/lobby");
    expect(JSON.parse(String(init.body))).toEqual({
      body: toB64Url(body),
      pubkey: toB64Url(pubkey),
      sig: toB64Url(sig),
      ctr: 7,
      nonce: 11,
    });
  });

  it("encodes a room name rather than letting it shape the path", async () => {
    reply({ epoch: "", last_ctr: {}, messages: [] });

    await roomMessages("chat:lobby");

    expect(call().url).toBe("/api/rooms/chat%3Alobby");
  });
});

describe("erase", () => {
  it("sends every token in the body, never in the URL", async () => {
    reply({ status: "erased", scrub: "pending" });

    const tokens = [
      new Uint8Array(32).fill(1),
      new Uint8Array(32).fill(2),
      new Uint8Array(32).fill(3),
    ];
    const result = await erase(tokens);

    const { url, init, headers } = call();
    expect(url).toBe("/api/erase");
    expect(init.method).toBe("POST");
    expect(headers["x-zifiri-owner"]).toBeUndefined();
    for (const token of tokens) expect(url).not.toContain(toB64(token));
    expect(JSON.parse(String(init.body))).toEqual({
      owner_tokens: tokens.map(toB64),
    });
    expect(result).toEqual({ status: "erased", scrub: "pending" });
  });

  it("requires at least one token", async () => {
    await expect(erase([])).rejects.toThrow(TypeError);
    expect(fetchMock).not.toHaveBeenCalled();
  });
});

describe("request envelope", () => {
  it("omits credentials and the referrer on every call", async () => {
    reply({ status: "deleted" });

    await closeListing(1, TOKEN);

    const { init } = call();
    expect(init.credentials).toBe("omit");
    expect(init.referrerPolicy).toBe("no-referrer");
    expect(init.cache).toBe("no-store");
  });

  it("parses a space-padded JSON answer", async () => {
    reply({ listings: [{ ref: 1 }] });

    await expect(listListings()).resolves.toEqual([{ ref: 1 }]);
  });

  it("maps a transport failure to code network", async () => {
    fetchMock.mockRejectedValueOnce(new TypeError("failed to fetch"));

    await expect(listListings()).rejects.toMatchObject({
      name: "ApiError",
      status: 0,
      code: "network",
    });
  });

  it("maps an unparseable error body to code error", async () => {
    fetchMock.mockResolvedValueOnce(new Response("nope", { status: 500 }));

    await expect(listListings()).rejects.toMatchObject({
      status: 500,
      code: "error",
    });
  });

  it("keeps ApiError an Error so callers can rethrow it", async () => {
    reply({ error: "refused" }, 429);

    const error = await listListings().catch((caught: unknown) => caught);
    expect(error).toBeInstanceOf(ApiError);
    expect(error).toBeInstanceOf(Error);
  });
});
