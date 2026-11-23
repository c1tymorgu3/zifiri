import { describe, expect, it, vi } from "vitest";
import {
  CATEGORY_LABELS,
  MAX_BODY,
  MAX_TITLE,
  composeListing,
  filterListings,
  fold,
  formatPrice,
  groupByCategory,
  renderListings,
  type ListingItem,
} from "../src/ui/listings";

function listing(overrides: Partial<ListingItem> = {}): ListingItem {
  return {
    id: "l1",
    title: "Wooden table",
    body: "Comes with two chairs, barely used.",
    price: 250000,
    currency: "TRY",
    category: "home",
    day: "2026-11-22",
    ...overrides,
  };
}

describe("fold", () => {
  it("collapses cases and accents into one letter", () => {
    expect(fold("CAFÉ")).toBe("cafe");
    expect(fold("Cafe")).toBe("cafe");
    expect(fold("cafe")).toBe("cafe");
    expect(fold("CAFÉ")).toBe("cafe");
  });
});

describe("filterListings", () => {
  it("returns a fresh copy of every listing when the filter is empty", () => {
    const items = [listing({ id: "a" }), listing({ id: "b", price: null })];
    const result = filterListings(items, {});
    expect(result).toEqual(items);
    expect(result).not.toBe(items);
  });

  it("matches an accented word whichever spelling the query uses", () => {
    const cafe = listing({ id: "a", title: "Table for a cafe" });
    const red = listing({ id: "b", title: "RED bicycle", body: "18 gears" });

    expect(filterListings([cafe, red], { q: "cafe" }).map((l) => l.id)).toEqual(["a"]);
    expect(filterListings([cafe, red], { q: "CAFÉ" }).map((l) => l.id)).toEqual(["a"]);
    expect(filterListings([cafe, red], { q: "red" }).map((l) => l.id)).toEqual(["b"]);
    expect(filterListings([cafe, red], { q: "RED" }).map((l) => l.id)).toEqual(["b"]);
  });

  it("folds the remaining diacritics so an ASCII keyboard still finds the listing", () => {
    const items = [listing({ id: "a", title: "Café table" }), listing({ id: "b", title: "Naïve print" })];
    expect(filterListings(items, { q: "cafe" }).map((l) => l.id)).toEqual(["a"]);
    expect(filterListings(items, { q: "naive" }).map((l) => l.id)).toEqual(["b"]);
    expect(filterListings(items, { q: "CAFÉ" }).map((l) => l.id)).toEqual(["a"]);
  });

  it("requires every word of a multi-word query, in any order", () => {
    const both = listing({ id: "a", title: "Wooden table", body: "walnut, two chairs" });
    const onlyOne = listing({ id: "b", title: "Wooden shelf", body: "wall shelf" });

    expect(filterListings([both, onlyOne], { q: "table wooden" }).map((l) => l.id)).toEqual(["a"]);
    expect(filterListings([both, onlyOne], { q: "  wooden   table " }).map((l) => l.id)).toEqual(["a"]);
    expect(filterListings([both, onlyOne], { q: "table chairs" }).map((l) => l.id)).toEqual(["a"]);
    expect(filterListings([both, onlyOne], { q: "table bicycle" })).toEqual([]);
  });

  it("searches the body as well as the title", () => {
    const items = [listing({ id: "a", title: "Table", body: "walnut veneer" })];
    expect(filterListings(items, { q: "walnut" }).map((l) => l.id)).toEqual(["a"]);
  });

  it("keeps both ends of the price range inclusive", () => {
    const items = [
      listing({ id: "low", price: 0 }),
      listing({ id: "min", price: 50000 }),
      listing({ id: "mid", price: 75000 }),
      listing({ id: "max", price: 100000 }),
      listing({ id: "high", price: 100001 }),
    ];
    expect(filterListings(items, { minPrice: 50000, maxPrice: 100000 }).map((l) => l.id)).toEqual([
      "min",
      "mid",
      "max",
    ]);
  });

  it("drops barter listings once any price bound is set", () => {
    const items = [listing({ id: "paid", price: 10000 }), listing({ id: "barter", price: null })];
    expect(filterListings(items, { minPrice: 0 }).map((l) => l.id)).toEqual(["paid"]);
    expect(filterListings(items, { maxPrice: 999999 }).map((l) => l.id)).toEqual(["paid"]);
  });

  it("filters by category, accepting the display label as well as the slug", () => {
    const items = [
      listing({ id: "a", category: "electronics" }),
      listing({ id: "b", category: "home" }),
      listing({ id: "c", category: "work" }),
    ];
    expect(filterListings(items, { category: "electronics" }).map((l) => l.id)).toEqual(["a"]);
    expect(filterListings(items, { category: "Electronics" }).map((l) => l.id)).toEqual(["a"]);
    expect(filterListings(items, { category: "Work" }).map((l) => l.id)).toEqual(["c"]);
    expect(filterListings(items, { category: "" })).toHaveLength(3);
  });

  it("combines query, category and price without widening the result", () => {
    const items = [
      listing({ id: "a", title: "Table", category: "home", price: 20000 }),
      listing({ id: "b", title: "Table", category: "home", price: 90000 }),
      listing({ id: "c", title: "Table", category: "work", price: 20000 }),
    ];
    expect(filterListings(items, { q: "table", category: "home", maxPrice: 50000 }).map((l) => l.id)).toEqual([
      "a",
    ]);
  });

  it("returns an empty array when nothing matches", () => {
    expect(filterListings([listing()], { q: "kayak" })).toEqual([]);
  });
});

describe("formatPrice", () => {
  it("formats cents as Turkish lira", () => {
    const text = formatPrice(123456, "TRY");
    expect(text).toContain("1,234.56");
    expect(text).toContain("₺");
  });

  it("prints zero without inventing a price", () => {
    expect(formatPrice(0, "TRY")).toContain("0.00");
  });

  it("says trade when the price is null or absent", () => {
    expect(formatPrice(null, "TRY")).toBe("trade");
    expect(formatPrice(undefined, "TRY")).toBe("trade");
  });

  it("honours the requested currency", () => {
    const text = formatPrice(1234, "USD");
    expect(text).toContain("12.34");
    expect(text).not.toContain("₺");
  });

  it("defaults to lira", () => {
    expect(formatPrice(500)).toContain("5.00");
  });
});

class FakeElement {
  className = "";
  textContent = "";
  type = "";
  dataset: Record<string, string> = {};
  children: FakeElement[] = [];
  private handlers: Array<() => void> = [];

  constructor(
    readonly tagName: string,
    readonly ownerDocument: FakeDocument,
  ) {}

  append(...nodes: FakeElement[]): void {
    this.children.push(...nodes);
  }

  replaceChildren(...nodes: FakeElement[]): void {
    this.children = nodes;
  }

  addEventListener(type: string, handler: () => void): void {
    if (type === "click") this.handlers.push(handler);
  }

  click(): void {
    for (const handler of this.handlers) handler();
  }

  allText(): string {
    return this.textContent + this.children.map((child) => child.allText()).join("");
  }

  classNames(): string[] {
    return [this.className, ...this.children.flatMap((child) => child.classNames())].filter(Boolean);
  }

  tags(): string[] {
    return [this.tagName, ...this.children.flatMap((child) => child.tags())];
  }
}

class FakeDocument {
  createElement(tag: string): FakeElement {
    return new FakeElement(tag, this);
  }
}

function fakeRoot(): FakeElement {
  return new FakeElement("div", new FakeDocument());
}

function render(items: ListingItem[], onOpen: (id: string) => void = () => {}): FakeElement {
  const root = fakeRoot();
  renderListings(root as unknown as HTMLElement, items, onOpen);
  return root;
}

describe("renderListings", () => {
  it("shows title, price, category and day — four fields, nothing more", () => {
    const root = render([listing({ title: "Wooden table", price: 250000, category: "home", day: "2026-11-22" })]);

    const button = root.children[0]?.children[0]?.children[0];
    expect(button?.className).toBe("listing");
    expect(button?.dataset["id"]).toBe("l1");
    expect(button?.children.map((child) => child.className)).toEqual([
      "listing-title",
      "listing-price",
      "listing-category",
      "listing-day",
    ]);
    expect(button?.children.map((child) => child.textContent)).toEqual([
      "Wooden table",
      formatPrice(250000, "TRY"),
      CATEGORY_LABELS.home,
      "2026-11-22",
    ]);
  });

  it("has no seller field to render, even if the object carries one", () => {
    const leaky: ListingItem & { seller: string } = { ...listing(), seller: "Mert Yilmaz" };
    const root = render([leaky]);

    expect(root.allText()).not.toContain("Mert");
    expect(root.classNames().some((name) => /seller/i.test(name))).toBe(false);
    expect(root.allText().toLowerCase()).not.toContain("seller");
  });

  it("says trade for a barter listing and marks it as such", () => {
    const root = render([listing({ price: null })]);
    const price = root.children[0]?.children[0]?.children[0]?.children[1];

    expect(price?.textContent).toBe("trade");
    expect(price?.className).toBe("listing-price trade");
  });

  it("renders an empty state instead of an empty list", () => {
    const root = render([]);

    expect(root.children).toHaveLength(1);
    expect(root.children[0]?.tagName).toBe("p");
    expect(root.children[0]?.className).toBe("empty");
    expect(root.allText()).toBe("No listings yet.");
  });

  it("opens the listing that was clicked", () => {
    const onOpen = vi.fn();
    const root = render([listing({ id: "a" }), listing({ id: "b" })], onOpen);

    root.children[0]?.children[1]?.children[0]?.click();
    expect(onOpen).toHaveBeenCalledWith("b");
  });

  it("keeps markup in a title as text, never as HTML", () => {
    const payload = '<img src=x onerror="alert(1)">';
    const root = render([listing({ title: payload })]);

    expect(root.allText()).toContain(payload);
    expect(root.tags()).not.toContain("img");
    expect(root.children[0]?.children[0]?.children[0]?.children).toHaveLength(4);
  });

  it("marks a missing day as unknown rather than showing a blank", () => {
    const root = render([listing({ day: "" })]);
    expect(root.children[0]?.children[0]?.children[0]?.children[3]?.textContent).toBe("unknown");
  });
});

describe("composeListing", () => {
  const valid = { title: "Table", body: "Walnut table.", price: 10000, category: "home" };

  it("accepts a draft at both length limits", () => {
    const result = composeListing({
      title: "a".repeat(MAX_TITLE),
      body: "b".repeat(MAX_BODY),
      price: 0,
      category: "electronics",
    });

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect([...result.value.title]).toHaveLength(MAX_TITLE);
    expect([...result.value.body]).toHaveLength(MAX_BODY);
    expect(result.value.price).toBe(0);
    expect(result.value.category).toBe("electronics");
  });

  it("trims the title and the body", () => {
    const result = composeListing({ ...valid, title: "  Table  ", body: "\n walnut table \n" });

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.value.title).toBe("Table");
    expect(result.value.body).toBe("walnut table");
  });

  it("rejects a title one character over the limit without echoing it", () => {
    const result = composeListing({ ...valid, title: "SECRET-TITLE ".repeat(10) });

    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.issues.map((issue) => issue.field)).toEqual(["title"]);
    expect(result.issues[0]?.code).toBe("too_long");
    expect(result.issues[0]?.message).toContain("Title");
    expect(result.issues[0]?.message).not.toContain("SECRET");
  });

  it("rejects a body one character over the limit without echoing it", () => {
    const result = composeListing({ ...valid, body: "x".repeat(MAX_BODY + 1) });

    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.issues.map((issue) => issue.field)).toEqual(["body"]);
    expect(result.issues[0]?.code).toBe("too_long");
    expect(result.issues[0]?.message).toContain("Body");
    expect(result.issues[0]?.message).not.toContain("xxxx");
  });

  it("rejects an empty title and an empty body, naming both fields", () => {
    const result = composeListing({ ...valid, title: "   ", body: "" });

    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.issues.map((issue) => issue.field)).toEqual(["title", "body"]);
    expect(result.issues.every((issue) => issue.code === "empty")).toBe(true);
  });

  it("treats a null price as trade", () => {
    const result = composeListing({ ...valid, price: null });

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.value.price).toBeNull();
  });

  it("rejects a negative price without repeating the number", () => {
    const result = composeListing({ ...valid, price: -1234 });

    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.issues[0]?.field).toBe("price");
    expect(result.issues[0]?.code).toBe("negative");
    expect(result.issues[0]?.message).toContain("Price");
    expect(result.issues[0]?.message).not.toContain("1234");
  });

  it("rejects a price that is not a finite number", () => {
    expect(composeListing({ ...valid, price: Number.NaN }).ok).toBe(false);
    expect(composeListing({ ...valid, price: Number.POSITIVE_INFINITY }).ok).toBe(false);
  });

  it("rejects fractional cents", () => {
    const result = composeListing({ ...valid, price: 12.5 });

    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.issues[0]?.field).toBe("price");
    expect(result.issues[0]?.code).toBe("not_a_number");
  });

  it("rejects a category outside the list", () => {
    const result = composeListing({ ...valid, category: "weapon" });

    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.issues[0]?.field).toBe("category");
    expect(result.issues[0]?.code).toBe("unknown_category");
    expect(result.issues[0]?.message).not.toContain("weapon");
  });

  it("accepts a category typed as its display label", () => {
    const result = composeListing({ ...valid, category: "Electronics" });

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.value.category).toBe("electronics");
  });

  it("reports every problem at once, each with its field", () => {
    const result = composeListing({
      title: "",
      body: "x".repeat(MAX_BODY + 1),
      price: -1,
      category: "nope",
    });

    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.issues.map((issue) => issue.field)).toEqual(["title", "body", "price", "category"]);
  });
});

describe("groupByCategory", () => {
  it("groups in first-seen order with English labels", () => {
    const items = [
      listing({ id: "a", category: "electronics" }),
      listing({ id: "b", category: "home" }),
      listing({ id: "c", category: "electronics" }),
    ];

    const groups = groupByCategory(items);
    expect(groups.map((group) => group.category)).toEqual(["electronics", "home"]);
    expect(groups.map((group) => group.label)).toEqual(["Electronics", "Home"]);
    expect(groups[0]?.items.map((item) => item.id)).toEqual(["a", "c"]);
  });

  it("returns nothing for an empty list", () => {
    expect(groupByCategory([])).toEqual([]);
  });

  it("keeps an unknown or missing category in its own group instead of guessing", () => {
    const groups = groupByCategory([listing({ category: "hidden" }), listing({ category: "" })]);
    expect(groups.map((group) => group.category)).toEqual(["hidden", "unknown"]);
  });
});
