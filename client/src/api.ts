import { decode, encode, PadError, type PadBucket } from "./pad";

/**
 * The whole client surface of the server (scope v5), and nothing else.
 *
 * Three rules live here rather than in the components:
 *
 *  - every listing description goes out padded, in one of the four bucket
 *    sizes, so a one-word listing and a four-kilobyte one are the same length
 *    on the wire;
 *  - a mailbox envelope must already be a 4096-byte sealed frame — a short
 *    envelope is refused locally rather than sent and rejected;
 *  - the owner token travels in exactly one place, the `x-zifiri-owner`
 *    header. It is never put in a query string, because a query string ends
 *    up in logs, proxy traces and browser history.
 *
 * Every request also omits cookies and the referrer: the client is the only
 * part of the system that could leak identity without the server seeing it.
 */

const BASE = "/api";
const OWNER_HEADER = "x-zifiri-owner";

/** The sealed-sender frame size the mailbox store accepts. */
export const MAILBOX_ENVELOPE_BYTES = 4096;

export class ApiError extends Error {
  override name = "ApiError";

  constructor(
    readonly status: number,
    readonly code: string,
  ) {
    super(`${status} ${code}`);
  }
}

type QueryValue = string | number | boolean | null | undefined;

interface RequestOptions {
  method?: string;
  json?: unknown;
  /** Raw 32-byte owner token; sent only as the `x-zifiri-owner` header. */
  token?: Uint8Array;
  query?: Record<string, QueryValue>;
}

/**
 * Builds a query string. A token-shaped key is a programming error: the
 * token has one legal carrier and this is not it.
 */
function buildQuery(query: Record<string, QueryValue> | undefined): string {
  if (query === undefined) return "";
  const parts: string[] = [];

  for (const [key, value] of Object.entries(query)) {
    if (/token/i.test(key)) {
      throw new Error(`owner tokens must not travel in the query string: ${key}`);
    }
    if (value === undefined || value === null) continue;
    if (typeof value === "string" && value === "") continue;
    parts.push(`${encodeURIComponent(key)}=${encodeURIComponent(String(value))}`);
  }

  return parts.length === 0 ? "" : `?${parts.join("&")}`;
}

async function request<T>(path: string, init: RequestOptions = {}): Promise<T> {
  const headers: Record<string, string> = { accept: "application/json" };
  let body: BodyInit | undefined;

  if (init.token !== undefined) {
    headers[OWNER_HEADER] = toB64(init.token);
  }

  if (init.json !== undefined) {
    headers["content-type"] = "application/json";
    body = JSON.stringify(init.json);
  }

  const requestInit: RequestInit = {
    method: init.method ?? "GET",
    headers,
    credentials: "omit",
    referrerPolicy: "no-referrer",
    cache: "no-store",
  };
  if (body !== undefined) requestInit.body = body;

  let response: Response;
  try {
    response = await fetch(BASE + path + buildQuery(init.query), requestInit);
  } catch {
    // A transport failure is not an HTTP status; `0` keeps the caller from
    // mistaking it for a server refusal it could act on.
    throw new ApiError(0, "network");
  }

  if (!response.ok) {
    throw new ApiError(response.status, await errorCode(response));
  }

  if (response.status === 204) return undefined as T;

  // Answers are padded to a fixed size with trailing spaces; JSON.parse
  // accepts trailing whitespace, so the padding costs the caller nothing.
  const text = await response.text();
  try {
    return JSON.parse(text) as T;
  } catch {
    throw new ApiError(response.status, "error");
  }
}

async function errorCode(response: Response): Promise<string> {
  try {
    const parsed = (await response.json()) as { error?: unknown };
    if (parsed && typeof parsed.error === "string" && parsed.error !== "") {
      return parsed.error;
    }
  } catch {
    // A body that is not JSON tells the caller nothing, which is the point.
  }
  return "error";
}

/* -- proof of work --------------------------------------------------------- */

export interface Challenge {
  id: string;
  bits: number;
}

/**
 * Asks for a challenge bound to this owner and these bytes. The payload hash
 * is public, so it is the one thing besides a cursor allowed in the query.
 */
export async function challenge(
  ownerToken: Uint8Array,
  payloadHash: Uint8Array,
): Promise<Challenge> {
  if (!(payloadHash instanceof Uint8Array) || payloadHash.length !== 32) {
    throw new TypeError("payloadHash must be a 32-byte Uint8Array");
  }

  const payload = await request<{ id?: unknown; bits?: unknown }>("/pow", {
    token: ownerToken,
    query: { payload_hash: toB64Url(payloadHash) },
  });

  return { id: String(payload.id ?? ""), bits: Number(payload.bits ?? 0) };
}

/* -- listings -------------------------------------------------------------- */

export interface Listing {
  ref: number;
  title: string;
  price_cents: number | null;
  currency: string;
  category: string;
  day: string | null;
  /** Base64. The server never puts raw bytes in JSON. */
  body_b64: string;
}

export interface ListingInput {
  title: string;
  body: string;
  category: string;
  ownerToken: Uint8Array;
  challengeId: string;
  nonce: number;
  bits: number;
  priceCents?: number | null;
  currency?: string;
  bucket?: PadBucket;
}

export interface CreatedListing {
  status: string;
  ref: number;
}

/** Pads a listing description; the server rejects anything else. */
export function paddedBody(body: string, bucket?: PadBucket): Uint8Array {
  return encode(new TextEncoder().encode(body), bucket);
}

export async function createListing(input: ListingInput): Promise<CreatedListing> {
  const envelope = paddedBody(input.body, input.bucket);

  return request<CreatedListing>("/listings", {
    method: "POST",
    token: input.ownerToken,
    json: {
      envelope: toB64(envelope),
      title: input.title,
      price_cents: input.priceCents ?? null,
      currency: input.currency ?? "USD",
      category: input.category,
      challenge_id: input.challengeId,
      nonce: input.nonce,
      bits: input.bits,
    },
  });
}

export interface ListingQuery {
  q?: string;
  category?: string;
  before?: number;
  limit?: number;
}

export async function listListings(query: ListingQuery = {}): Promise<Listing[]> {
  const payload = await request<{ listings?: Listing[] }>("/listings", {
    query: {
      q: query.q,
      category: query.category,
      before: query.before,
      limit: query.limit,
    },
  });

  return payload.listings ?? [];
}

export async function getListing(ref: number | string): Promise<Listing> {
  const payload = await request<{ listing?: Listing }>(
    `/listings/${encodeURIComponent(String(ref))}`,
  );
  if (payload.listing === undefined) throw new ApiError(404, "not_found");
  return payload.listing;
}

/** Decodes a listing body; a body that will not decode reads as empty. */
export function listingText(listing: Pick<Listing, "body_b64">): string {
  try {
    return new TextDecoder().decode(decode(fromB64(listing.body_b64)));
  } catch {
    return "";
  }
}

/** Closing is the owner's delete; the token is the capability, so no proof. */
export async function closeListing(
  ref: number | string,
  ownerToken: Uint8Array,
): Promise<{ status: string }> {
  return request<{ status: string }>(
    `/listings/${encodeURIComponent(String(ref))}`,
    { method: "DELETE", token: ownerToken },
  );
}

/* -- sealed-sender mailbox ------------------------------------------------- */

export interface MailboxMessage {
  id: number;
  envelope_b64: string;
}

export interface MailboxPage {
  messages: MailboxMessage[];
  cursor: number;
  more: boolean;
}

/** `recipientPk` is the 32-byte public key the envelope is sealed to. */
export async function deliverEnvelope(
  recipientPk: Uint8Array,
  envelope: Uint8Array,
): Promise<{ status: string }> {
  if (!(envelope instanceof Uint8Array) || envelope.length !== MAILBOX_ENVELOPE_BYTES) {
    throw new PadError(`mailbox envelope must be ${MAILBOX_ENVELOPE_BYTES} bytes`);
  }
  if (!(recipientPk instanceof Uint8Array) || recipientPk.length !== 32) {
    throw new TypeError("recipientPk must be a 32-byte Uint8Array");
  }

  return request<{ status: string }>(
    `/mailbox/${encodeURIComponent(toB64(recipientPk))}`,
    {
      method: "POST",
      json: { envelope: toB64(envelope) },
    },
  );
}

export async function fetchMailbox(
  recipientPk: Uint8Array,
  since: number | string | null = null,
): Promise<MailboxPage> {
  if (!(recipientPk instanceof Uint8Array) || recipientPk.length !== 32) {
    throw new TypeError("recipientPk must be a 32-byte Uint8Array");
  }

  const payload = await request<Partial<MailboxPage>>(
    `/mailbox/${encodeURIComponent(toB64(recipientPk))}`,
    { query: { since } },
  );

  return {
    messages: payload.messages ?? [],
    cursor: Number(payload.cursor ?? 0),
    more: payload.more === true,
  };
}

export async function ackMailbox(
  recipientPk: Uint8Array,
  ids: readonly number[],
): Promise<{ status: string }> {
  if (!(recipientPk instanceof Uint8Array) || recipientPk.length !== 32) {
    throw new TypeError("recipientPk must be a 32-byte Uint8Array");
  }

  return request<{ status: string }>("/mailbox/ack", {
    method: "POST",
    json: { recipient_pk: toB64(recipientPk), ids: [...ids] },
  });
}

/* -- rooms ----------------------------------------------------------------- */

export interface RoomWireMessage {
  id: number;
  /** URL-safe base64, unpadded. */
  pubkey: string;
  sig: string;
  body: string;
  bucket: number;
  ctr: number;
}

export interface RoomPage {
  epoch: string;
  last_ctr: Record<string, number>;
  messages: RoomWireMessage[];
}

export async function roomMessages(
  room: string,
  since: number | string | null = null,
): Promise<RoomPage> {
  const payload = await request<Partial<RoomPage>>(
    `/rooms/${encodeURIComponent(room)}`,
    { query: { since } },
  );

  return {
    epoch: String(payload.epoch ?? ""),
    last_ctr: payload.last_ctr ?? {},
    messages: payload.messages ?? [],
  };
}

export interface RoomPostInput {
  /** Unpadded plaintext; the server pads it to a chat bucket. */
  body: Uint8Array;
  pubkey: Uint8Array;
  sig: Uint8Array;
  ctr: number;
  nonce: number;
}

export interface PostedRoomMessage {
  status: string;
  ref: number;
  epoch: string;
}

export async function postRoomMessage(
  room: string,
  input: RoomPostInput,
): Promise<PostedRoomMessage> {
  return request<PostedRoomMessage>(`/rooms/${encodeURIComponent(room)}`, {
    method: "POST",
    json: {
      body: toB64Url(input.body),
      pubkey: toB64Url(input.pubkey),
      sig: toB64Url(input.sig),
      ctr: input.ctr,
      nonce: input.nonce,
    },
  });
}

/* -- "vanish" -------------------------------------------------------------- */

export interface EraseResult {
  status: string;
  scrub?: string;
}

/**
 * Identity-level erase: every token the device has used, in one request.
 *
 * This is the one endpoint whose payload is a list of tokens, because the
 * whole point is to erase every identity index at once; the single-token
 * operations still carry the token only in the header. The list is a body
 * field — never a query string.
 */
export async function erase(tokens: readonly Uint8Array[]): Promise<EraseResult> {
  if (tokens.length === 0) throw new TypeError("erase needs at least one token");

  return request<EraseResult>("/erase", {
    method: "POST",
    json: { owner_tokens: tokens.map(toB64) },
  });
}

/* -- encoding -------------------------------------------------------------- */

export { decode as decodeBody };

export function toB64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

/** URL-safe, unpadded base64 — the form chat keys and hashes travel in. */
export function toB64Url(bytes: Uint8Array): string {
  return toB64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function fromB64(value: string): Uint8Array {
  const binary = atob(value);
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) out[i] = binary.charCodeAt(i);
  return out;
}
