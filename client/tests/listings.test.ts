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
    title: "Ahşap masa",
    body: "İki sandalyeyle birlikte, az kullanıldı.",
    price: 250000,
    currency: "TRY",
    category: "ev",
    day: "2026-11-22",
    ...overrides,
  };
}

describe("fold", () => {
  it("collapses the four Turkish i's into one letter", () => {
    expect(fold("İSTANBUL")).toBe("istanbul");
    expect(fold("ISTANBUL")).toBe("istanbul");
    expect(fold("ıstanbul")).toBe("istanbul");
    expect(fold("istanbul")).toBe("istanbul");
  });
});

describe("filterListings", () => {
  it("returns a fresh copy of every listing when the filter is empty", () => {
    const items = [listing({ id: "a" }), listing({ id: "b", price: null })];
    const result = filterListings(items, {});
    expect(result).toEqual(items);
    expect(result).not.toBe(items);
  });

  it("matches İ and ı regardless of which one the query uses", () => {
    const istanbul = listing({ id: "a", title: "İSTANBUL'da kiralık masa" });
    const kirmizi = listing({ id: "b", title: "KIRMIZI bisiklet", body: "18 vites" });

    expect(filterListings([istanbul, kirmizi], { q: "istanbul" }).map((l) => l.id)).toEqual(["a"]);
    expect(filterListings([istanbul, kirmizi], { q: "ıstanbul" }).map((l) => l.id)).toEqual(["a"]);
    expect(filterListings([istanbul, kirmizi], { q: "kırmızı" }).map((l) => l.id)).toEqual(["b"]);
    expect(filterListings([istanbul, kirmizi], { q: "KIRMIZI" }).map((l) => l.id)).toEqual(["b"]);
  });

  it("folds the other Turkish letters so an ASCII keyboard still finds the listing", () => {
    const items = [listing({ id: "a", title: "Gül fidanı" }), listing({ id: "b", title: "Çelik tencere" })];
    expect(filterListings(items, { q: "gul" }).map((l) => l.id)).toEqual(["a"]);
    expect(filterListings(items, { q: "celik" }).map((l) => l.id)).toEqual(["b"]);
    expect(filterListings(items, { q: "GÜL" }).map((l) => l.id)).toEqual(["a"]);
  });

  it("requires every word of a multi-word query, in any order", () => {
    const both = listing({ id: "a", title: "Ahşap masa", body: "ceviz, iki sandalye" });
    const onlyOne = listing({ id: "b", title: "Ahşap raf", body: "duvar rafı" });

    expect(filterListings([both, onlyOne], { q: "masa ahşap" }).map((l) => l.id)).toEqual(["a"]);
    expect(filterListings([both, onlyOne], { q: "  ahşap   masa " }).map((l) => l.id)).toEqual(["a"]);
    expect(filterListings([both, onlyOne], { q: "masa sandalye" }).map((l) => l.id)).toEqual(["a"]);
    expect(filterListings([both, onlyOne], { q: "masa bisiklet" })).toEqual([]);
  });

  it("searches the body as well as the title", () => {
    const items = [listing({ id: "a", title: "Masa", body: "ceviz kaplama" })];
    expect(filterListings(items, { q: "ceviz" }).map((l) => l.id)).toEqual(["a"]);
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
      listing({ id: "a", category: "elektronik" }),
      listing({ id: "b", category: "ev" }),
      listing({ id: "c", category: "is" }),
    ];
    expect(filterListings(items, { category: "elektronik" }).map((l) => l.id)).toEqual(["a"]);
    expect(filterListings(items, { category: "Elektronik" }).map((l) => l.id)).toEqual(["a"]);
    expect(filterListings(items, { category: "İş" }).map((l) => l.id)).toEqual(["c"]);
    expect(filterListings(items, { category: "" })).toHaveLength(3);
  });

  it("combines query, category and price without widening the result", () => {
    const items = [
      listing({ id: "a", title: "Masa", category: "ev", price: 20000 }),
      listing({ id: "b", title: "Masa", category: "ev", price: 90000 }),
      listing({ id: "c", title: "Masa", category: "is", price: 20000 }),
    ];
    expect(filterListings(items, { q: "masa", category: "ev", maxPrice: 50000 }).map((l) => l.id)).toEqual([
      "a",
    ]);
  });

  it("returns an empty array when nothing matches", () => {
    expect(filterListings([listing()], { q: "kayık" })).toEqual([]);
  });
});

describe("formatPrice", () => {
  it("formats kuruş as Turkish lira", () => {
    const text = formatPrice(123456, "TRY");
    expect(text).toContain("1.234,56");
    expect(text).toContain("₺");
  });

  it("prints zero without inventing a price", () => {
    expect(formatPrice(0, "TRY")).toContain("0,00");
  });

  it("says takas when the price is null or absent", () => {
    expect(formatPrice(null, "TRY")).toBe("takas");
    expect(formatPrice(undefined, "TRY")).toBe("takas");
  });

  it("honours the requested currency", () => {
    const text = formatPrice(1234, "USD");
    expect(text).toContain("12,34");
    expect(text).not.toContain("₺");
  });

  it("defaults to lira", () => {
    expect(formatPrice(500)).toContain("5,00");
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
    const root = render([listing({ title: "Ahşap masa", price: 250000, category: "ev", day: "2026-11-22" })]);

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
      "Ahşap masa",
      formatPrice(250000, "TRY"),
      CATEGORY_LABELS.ev,
      "2026-11-22",
    ]);
  });

  it("has no seller field to render, even if the object carries one", () => {
    const leaky: ListingItem & { seller: string } = { ...listing(), seller: "Ahmet Yılmaz" };
    const root = render([leaky]);

    expect(root.allText()).not.toContain("Ahmet");
    expect(root.classNames().some((name) => /seller|satici|satıcı/i.test(name))).toBe(false);
    expect(root.allText().toLowerCase()).not.toContain("satıcı");
  });

  it("says takas for a barter listing and marks it as such", () => {
    const root = render([listing({ price: null })]);
    const price = root.children[0]?.children[0]?.children[0]?.children[1];

    expect(price?.textContent).toBe("takas");
    expect(price?.className).toBe("listing-price takas");
  });

  it("renders an empty state instead of an empty list", () => {
    const root = render([]);

    expect(root.children).toHaveLength(1);
    expect(root.children[0]?.tagName).toBe("p");
    expect(root.children[0]?.className).toBe("empty");
    expect(root.allText()).toBe("Henüz ilan yok.");
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
    expect(root.children[0]?.children[0]?.children[0]?.children[3]?.textContent).toBe("bilinmiyor");
  });
});

describe("composeListing", () => {
  const valid = { title: "Masa", body: "Ceviz masa.", price: 10000, category: "ev" };

  it("accepts a draft at both length limits", () => {
    const result = composeListing({
      title: "a".repeat(MAX_TITLE),
      body: "b".repeat(MAX_BODY),
      price: 0,
      category: "elektronik",
    });

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect([...result.value.title]).toHaveLength(MAX_TITLE);
    expect([...result.value.body]).toHaveLength(MAX_BODY);
    expect(result.value.price).toBe(0);
    expect(result.value.category).toBe("elektronik");
  });

  it("trims the title and the body", () => {
    const result = composeListing({ ...valid, title: "  Masa  ", body: "\n ceviz masa \n" });

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.value.title).toBe("Masa");
    expect(result.value.body).toBe("ceviz masa");
  });

  it("rejects a title one character over the limit without echoing it", () => {
    const result = composeListing({ ...valid, title: "GİZLİ-BAŞLIK ".repeat(10) });

    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.issues.map((issue) => issue.field)).toEqual(["title"]);
    expect(result.issues[0]?.code).toBe("too_long");
    expect(result.issues[0]?.message).toContain("Başlık");
    expect(result.issues[0]?.message).not.toContain("GİZLİ");
  });

  it("rejects a body one character over the limit without echoing it", () => {
    const result = composeListing({ ...valid, body: "x".repeat(MAX_BODY + 1) });

    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.issues.map((issue) => issue.field)).toEqual(["body"]);
    expect(result.issues[0]?.code).toBe("too_long");
    expect(result.issues[0]?.message).toContain("Gövde");
    expect(result.issues[0]?.message).not.toContain("xxxx");
  });

  it("rejects an empty title and an empty body, naming both fields", () => {
    const result = composeListing({ ...valid, title: "   ", body: "" });

    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.issues.map((issue) => issue.field)).toEqual(["title", "body"]);
    expect(result.issues.every((issue) => issue.code === "empty")).toBe(true);
  });

  it("treats a null price as takas", () => {
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
    expect(result.issues[0]?.message).toContain("Fiyat");
    expect(result.issues[0]?.message).not.toContain("1234");
  });

  it("rejects a price that is not a finite number", () => {
    expect(composeListing({ ...valid, price: Number.NaN }).ok).toBe(false);
    expect(composeListing({ ...valid, price: Number.POSITIVE_INFINITY }).ok).toBe(false);
  });

  it("rejects fractional kuruş", () => {
    const result = composeListing({ ...valid, price: 12.5 });

    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.issues[0]?.field).toBe("price");
    expect(result.issues[0]?.code).toBe("not_a_number");
  });

  it("rejects a category outside the list", () => {
    const result = composeListing({ ...valid, category: "silah" });

    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.issues[0]?.field).toBe("category");
    expect(result.issues[0]?.code).toBe("unknown_category");
    expect(result.issues[0]?.message).not.toContain("silah");
  });

  it("accepts a category typed as its display label", () => {
    const result = composeListing({ ...valid, category: "Elektronik" });

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.value.category).toBe("elektronik");
  });

  it("reports every problem at once, each with its field", () => {
    const result = composeListing({
      title: "",
      body: "x".repeat(MAX_BODY + 1),
      price: -1,
      category: "yok",
    });

    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.issues.map((issue) => issue.field)).toEqual(["title", "body", "price", "category"]);
  });
});

describe("groupByCategory", () => {
  it("groups in first-seen order with Turkish labels", () => {
    const items = [
      listing({ id: "a", category: "elektronik" }),
      listing({ id: "b", category: "ev" }),
      listing({ id: "c", category: "elektronik" }),
    ];

    const groups = groupByCategory(items);
    expect(groups.map((group) => group.category)).toEqual(["elektronik", "ev"]);
    expect(groups.map((group) => group.label)).toEqual(["Elektronik", "Ev ve yaşam"]);
    expect(groups[0]?.items.map((item) => item.id)).toEqual(["a", "c"]);
  });

  it("returns nothing for an empty list", () => {
    expect(groupByCategory([])).toEqual([]);
  });

  it("keeps an unknown or missing category in its own group instead of guessing", () => {
    const groups = groupByCategory([listing({ category: "gizli" }), listing({ category: "" })]);
    expect(groups.map((group) => group.category)).toEqual(["gizli", "bilinmiyor"]);
  });
});
