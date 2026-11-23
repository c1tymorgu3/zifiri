/**
 * Listings UI (scope v5, "listings — a narrow claim").
 *
 * A listing is permanent and public, so the only claim it makes is the narrow
 * one: there is no account, address, or e-mail behind it. That claim has a
 * shape in this file — a listing has no seller field at all. Not an empty
 * string, not a hidden input: no property, so nothing to render and nothing
 * to leak. `owner_hash` stays on the server, behind the pepper.
 *
 * Everything that reaches the page goes in through `textContent`; a listing
 * body is untrusted input by construction.
 */
/**
 * Categories are canonical slugs, not display text: they travel in filters
 * and URLs. `CATEGORY_LABELS` is the only place the display spelling lives.
 */
export const LISTING_CATEGORIES = [
  "electronics",
  "home",
  "transport",
  "clothing",
  "service",
  "work",
  "other",
] as const;

export type ListingCategory = (typeof LISTING_CATEGORIES)[number];

export const CATEGORY_LABELS: Record<ListingCategory, string> = {
  electronics: "Electronics",
  home: "Home",
  transport: "Transport",
  clothing: "Clothing",
  service: "Service",
  work: "Work",
  other: "Other",
};

/** Server limits; the client refuses before the request is signed. */
export const MAX_TITLE = 120;
export const MAX_BODY = 8000;

/**
 * A listing as the API returns it. `day` is a date, not a timestamp: listings
 * keep no clock. A barter listing has no number, so `price` is `null` and is
 * rendered as "trade".
 */
export interface ListingItem {
  id: string;
  title: string;
  body: string;
  /** Cents. `null` = trade. */
  price: number | null;
  /** ISO 4217, e.g. "USD". */
  currency: string;
  category: string;
  /** YYYY-MM-DD. */
  day: string;
}

export interface ListingFilter {
  q?: string;
  category?: string;
  /** Cents, inclusive. */
  minPrice?: number;
  maxPrice?: number;
}

/**
 * Diacritic-insensitive fold: "Cafe", "Café" and "CAFÉ" all end up as "cafe",
 * and a dotless i (U+0131) collapses onto "i", so an ASCII keyboard still finds
 * a word it cannot spell.
 *
 * Order matters: `toLocaleLowerCase("tr")` maps "I" onto U+0131 and U+0130 onto
 * "i" before the combining dot of the latter is stripped, so neither letter can
 * survive as a mismatch.
 */
export function fold(text: string): string {
  return text
    .normalize("NFD")
    .toLocaleLowerCase("tr")
    .normalize("NFD")
    .replace(/\p{M}/gu, "")
    .replace(/\u0131/g, "i");
}

/**
 * Every whitespace-separated word must appear in the title or the body, in any
 * order. A price bound is a numeric claim, so barter listings drop out as soon
 * as one is set — "trade" cannot be compared to 5,000 cents.
 */
export function filterListings(items: readonly ListingItem[], filter: ListingFilter = {}): ListingItem[] {
  const tokens = (filter.q ?? "")
    .trim()
    .split(/\s+/)
    .filter((token) => token.length > 0)
    .map(fold);

  const wanted = filter.category === undefined ? "" : fold(filter.category.trim());

  const min = typeof filter.minPrice === "number" && Number.isFinite(filter.minPrice) ? filter.minPrice : null;
  const max = typeof filter.maxPrice === "number" && Number.isFinite(filter.maxPrice) ? filter.maxPrice : null;

  return items.filter((listing) => {
    if (wanted !== "" && fold(listing.category) !== wanted) return false;

    if (tokens.length > 0) {
      const haystack = fold(`${listing.title}\n${listing.body}`);
      if (!tokens.every((token) => haystack.includes(token))) return false;
    }

    if (min !== null || max !== null) {
      if (listing.price === null) return false;
      if (min !== null && listing.price < min) return false;
      if (max !== null && listing.price > max) return false;
    }

    return true;
  });
}

const formatters = new Map<string, Intl.NumberFormat | null>();

function currencyFormatter(currency: string): Intl.NumberFormat | null {
  const cached = formatters.get(currency);
  if (cached !== undefined) return cached;

  let formatter: Intl.NumberFormat | null;
  try {
    formatter = new Intl.NumberFormat("en-GB", {
      style: "currency",
      currency,
      currencyDisplay: "narrowSymbol",
    });
  } catch {
    // Unknown ISO code: fall back to a plain grouped number plus the code
    // rather than throwing inside a render loop.
    formatter = null;
  }
  formatters.set(currency, formatter);
  return formatter;
}

/**
 * `formatPrice(123456, "USD")` → "$1,234.56" on an en-GB locale.
 * `null` is the barter price and prints as "trade" — the absence of a number
 * is a fact about the listing, not a missing value.
 */
export function formatPrice(cents: number | null | undefined, currency = "USD"): string {
  if (cents === null || cents === undefined) return "trade";
  if (!Number.isFinite(cents)) return "—";

  const amount = cents / 100;
  const formatter = currencyFormatter(currency);
  if (formatter === null) {
    return `${new Intl.NumberFormat("en-GB").format(amount)} ${currency}`;
  }
  return formatter.format(amount);
}

export function categoryLabel(category: string): string {
  const exact = CATEGORY_LABELS[category as ListingCategory];
  if (exact !== undefined) return exact;

  const folded = fold(category);
  const match = LISTING_CATEGORIES.find((candidate) => fold(candidate) === folded);
  return match === undefined ? category : CATEGORY_LABELS[match];
}

/**
 * Renders title, price, category and day — four spans and a button. There is
 * no seller row because `ListingItem` has no seller: if a caller smuggles an
 * extra property onto the object, it is never read here.
 */
export function renderListings(
  root: HTMLElement,
  items: readonly ListingItem[],
  onOpen: (id: string) => void,
): void {
  const doc = root.ownerDocument;
  root.replaceChildren();

  if (items.length === 0) {
    const empty = doc.createElement("p");
    empty.className = "empty";
    empty.textContent = "No listings yet.";
    root.append(empty);
    return;
  }

  const list = doc.createElement("ul");
  list.className = "listings";

  for (const listing of items) {
    const item = doc.createElement("li");

    const button = doc.createElement("button");
    button.type = "button";
    button.className = "listing";
    button.dataset.id = listing.id;
    button.addEventListener("click", () => onOpen(listing.id));

    const title = doc.createElement("span");
    title.className = "listing-title";
    title.textContent = listing.title;

    const price = doc.createElement("span");
    price.className = listing.price === null ? "listing-price trade" : "listing-price";
    price.textContent = formatPrice(listing.price, listing.currency);

    const category = doc.createElement("span");
    category.className = "listing-category";
    category.textContent = categoryLabel(listing.category);

    const day = doc.createElement("span");
    day.className = "listing-day";
    day.textContent = listing.day.trim() === "" ? "unknown" : listing.day;

    button.append(title, price, category, day);
    item.append(button);
    list.append(item);
  }

  root.append(list);
}

export type ListingField = "title" | "body" | "price" | "category";

export type ListingIssueCode = "empty" | "too_long" | "not_a_number" | "negative" | "unknown_category";

/**
 * A validation failure names the field and never repeats the input. Echoing a
 * rejected title into an error string is how a page ends up rendering the
 * thing it just refused.
 */
export interface ListingIssue {
  field: ListingField;
  code: ListingIssueCode;
  message: string;
}

export interface ListingDraft {
  title: string;
  body: string;
  price: number | null;
  category: string;
}

export interface ListingValue {
  title: string;
  body: string;
  price: number | null;
  category: ListingCategory;
}

export type ComposeResult = { ok: true; value: ListingValue } | { ok: false; issues: ListingIssue[] };

function codePoints(text: string): number {
  return [...text].length;
}

function canonicalCategory(input: string): ListingCategory | null {
  const folded = fold(input.trim());
  if (folded === "") return null;
  return LISTING_CATEGORIES.find((candidate) => fold(candidate) === folded) ?? null;
}

/** Collects every problem instead of stopping at the first one. */
export function composeListing(draft: ListingDraft): ComposeResult {
  const issues: ListingIssue[] = [];

  const title = typeof draft.title === "string" ? draft.title.trim() : "";
  if (title === "") {
    issues.push({ field: "title", code: "empty", message: "Title cannot be empty." });
  } else if (codePoints(title) > MAX_TITLE) {
    issues.push({
      field: "title",
      code: "too_long",
      message: `Title can be at most ${MAX_TITLE} characters.`,
    });
  }

  const body = typeof draft.body === "string" ? draft.body.trim() : "";
  if (body === "") {
    issues.push({ field: "body", code: "empty", message: "Body cannot be empty." });
  } else if (codePoints(body) > MAX_BODY) {
    issues.push({
      field: "body",
      code: "too_long",
      message: `Body can be at most ${MAX_BODY} characters.`,
    });
  }

  let price: number | null = null;
  if (draft.price !== null) {
    if (typeof draft.price !== "number" || !Number.isFinite(draft.price)) {
      issues.push({
        field: "price",
        code: "not_a_number",
        message: "Price must be a number; leave it empty for a trade.",
      });
    } else if (!Number.isInteger(draft.price)) {
      issues.push({
        field: "price",
        code: "not_a_number",
        message: "Price must be a whole number of cents.",
      });
    } else if (draft.price < 0) {
      issues.push({ field: "price", code: "negative", message: "Price cannot be negative." });
    } else {
      price = draft.price;
    }
  }

  const category = canonicalCategory(typeof draft.category === "string" ? draft.category : "");
  if (category === null) {
    issues.push({ field: "category", code: "unknown_category", message: "Category is not in the list." });
  }

  if (issues.length > 0 || category === null) return { ok: false, issues };

  return { ok: true, value: { title, body, price, category } };
}

export interface CategoryGroup {
  category: string;
  label: string;
  items: ListingItem[];
}

/** First-seen order, so a grouped view keeps the order the server sent. */
export function groupByCategory(items: readonly ListingItem[]): CategoryGroup[] {
  const groups = new Map<string, ListingItem[]>();

  for (const listing of items) {
    const key = listing.category.trim() === "" ? "unknown" : listing.category;
    const existing = groups.get(key);
    if (existing) existing.push(listing);
    else groups.set(key, [listing]);
  }

  return [...groups.entries()].map(([category, grouped]) => ({
    category,
    label: categoryLabel(category),
    items: grouped,
  }));
}
