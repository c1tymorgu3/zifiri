/**
 * İlanlar yüzeyi testleri.
 *
 * Yüzey gerçek DOM'a karşı yazılmıştır ama testler küçük bir sahte DOM'a
 * karşı koşar: bu depoda jsdom yok, ve sınanan şey tarayıcının kendisi değil,
 * yüzeyin kurduğu yapı — hangi düğme çizilir, hangi metin okunur, hangi
 * doğrulama reddeder.
 */
import { describe, expect, it, vi } from "vitest";

import {
  createListingsView,
  draftFromFields,
  emptyComposeFields,
  emptyMessage,
  filterFromForm,
  filtersBodyClass,
  hasOwnerToken,
  parsePrice,
  renderListingDetail,
  renderListingList,
} from "../src/ui/listings-view";
import {
  MAX_BODY,
  MAX_TITLE,
  type ListingFilter,
  type ListingItem,
} from "../src/ui/listings";

/* --------------------------------------------------------------- sahte DOM */

interface FakeEvent {
  preventDefault(): void;
}

type Handler = (event?: FakeEvent) => void;

class FakeElement {
  className = "";
  textContent = "";
  value = "";
  type = "";
  hidden = false;
  disabled = false;
  checked = false;
  dataset: Record<string, string> = {};
  attrs: Record<string, string> = {};
  children: FakeElement[] = [];
  handlers: Record<string, Handler[]> = {};
  readonly ownerDocument: FakeDocument;
  readonly tagName: string;

  constructor(tagName: string, doc: FakeDocument) {
    this.tagName = tagName;
    this.ownerDocument = doc;
  }

  append(...nodes: FakeElement[]): void {
    this.children.push(...nodes);
  }

  replaceChildren(...nodes: FakeElement[]): void {
    this.children = nodes;
    this.textContent = "";
  }

  addEventListener(type: string, handler: Handler): void {
    const bucket = this.handlers[type];
    if (bucket) bucket.push(handler);
    else this.handlers[type] = [handler];
  }

  setAttribute(name: string, value: string): void {
    this.attrs[name] = value;
  }

  getAttribute(name: string): string | null {
    return this.attrs[name] ?? null;
  }

  fire(type: string): void {
    for (const handler of this.handlers[type] ?? []) handler({ preventDefault() {} });
  }

  click(): void {
    this.fire("click");
  }

  walk(): FakeElement[] {
    const out: FakeElement[] = [];
    for (const child of this.children) out.push(child, ...child.walk());
    return out;
  }

  find(predicate: (element: FakeElement) => boolean): FakeElement | undefined {
    return this.walk().find(predicate);
  }

  findAll(predicate: (element: FakeElement) => boolean): FakeElement[] {
    return this.walk().filter(predicate);
  }

  text(): string {
    return [this.textContent, ...this.children.map((child) => child.text())].join(" ").trim();
  }
}

class FakeDocument {
  createElement(tagName: string): FakeElement {
    return new FakeElement(tagName, this);
  }
}

function mountPoint(): FakeElement {
  const doc = new FakeDocument();
  return doc.createElement("div");
}

const asRoot = (element: FakeElement): HTMLElement => element as unknown as HTMLElement;

/* ------------------------------------------------------------------ veri */

function listing(overrides: Partial<ListingItem> = {}): ListingItem {
  return {
    id: "l1",
    title: "Ceviz masa",
    body: "Altı kişilik, sağlam.",
    price: 250000,
    currency: "TRY",
    category: "ev",
    day: "2026-11-20",
    ...overrides,
  };
}

const byField = (name: string) => (element: FakeElement) => element.dataset.field === name;
const byRole = (name: string) => (element: FakeElement) => element.dataset.role === name;

/* ------------------------------------------------------------------ fiyat */

describe("parsePrice", () => {
  it("reads Turkish grouping and kuruş", () => {
    expect(parsePrice("1.250,50")).toEqual({ ok: true, cents: 125050 });
    expect(parsePrice("1.000.000")).toEqual({ ok: true, cents: 100000000 });
    expect(parsePrice("1250")).toEqual({ ok: true, cents: 125000 });
    expect(parsePrice("0,5")).toEqual({ ok: true, cents: 50 });
  });

  it("treats an empty field as takas, not as zero", () => {
    expect(parsePrice("")).toEqual({ ok: true, cents: null });
    expect(parsePrice("   ")).toEqual({ ok: true, cents: null });
  });

  it("refuses a dot decimal, a negative and letters instead of guessing", () => {
    expect(parsePrice("12.34").ok).toBe(false);
    expect(parsePrice("-5").ok).toBe(false);
    expect(parsePrice("abc").ok).toBe(false);
    expect(parsePrice("1,234").ok).toBe(false);
  });
});

/* ---------------------------------------------------------------- filtre */

describe("filterFromForm", () => {
  it("drops empty fields instead of sending empty bounds", () => {
    expect(filterFromForm({ q: "  ", category: "", min: "", max: "" })).toEqual({});
  });

  it("keeps a real query, a category and both bounds", () => {
    const filter = filterFromForm({ q: " masa ", category: "ev", min: "1.000", max: "3.000,50" });

    expect(filter).toEqual({
      q: "masa",
      category: "ev",
      minPrice: 100000,
      maxPrice: 300050,
    } satisfies ListingFilter);
  });

  it("ignores a bound that does not parse rather than widening the range", () => {
    expect(filterFromForm({ q: "", category: "", min: "abc", max: "" })).toEqual({});
  });
});

describe("empty and collapse helpers", () => {
  it("names the reason an empty list is empty", () => {
    expect(emptyMessage(false)).toContain("Henüz ilan yok");
    expect(emptyMessage(true)).toContain("filtreye uyan");
  });

  it("flips the mobile collapse class", () => {
    expect(filtersBodyClass(false)).toBe("listings-filters-body is-collapsed");
    expect(filtersBodyClass(true)).toBe("listings-filters-body is-open");
  });

  it("accepts only a non-blank owner token", () => {
    expect(hasOwnerToken("abc")).toBe(true);
    expect(hasOwnerToken("   ")).toBe(false);
    expect(hasOwnerToken(null)).toBe(false);
    expect(hasOwnerToken(undefined)).toBe(false);
  });
});

/* ------------------------------------------------------------------ liste */

describe("listing rows", () => {
  it("renders title, price, category chip and day — and no seller", () => {
    const root = mountPoint();
    renderListingList(asRoot(root), [listing()], {}, () => {});

    const row = root.find((element) => element.className === "listing");
    expect(row).toBeDefined();
    if (!row) return;

    expect(row.children).toHaveLength(4);
    expect(row.find((element) => element.className === "listing-title")?.textContent).toBe("Ceviz masa");
    expect(row.find((element) => element.className === "listing-price")?.textContent).toBe("₺2.500,00");
    expect(row.find((element) => element.className === "listing-category")?.textContent).toBe("Ev ve yaşam");
    expect(row.find((element) => element.className === "listing-day")?.textContent).toBe("2026-11-20");
    expect(root.find((element) => element.className.includes("seller"))).toBeUndefined();
    expect(root.text()).not.toContain("Satıcı");
  });

  it("prints a barter listing as takas, with the muted class", () => {
    const root = mountPoint();
    renderListingList(asRoot(root), [listing({ price: null })], {}, () => {});

    const price = root.find((element) => element.className.includes("listing-price"));
    expect(price?.textContent).toBe("takas");
    expect(price?.className).toContain("takas");
  });

  it("says why the list is empty, and changes the sentence once a filter is set", () => {
    const plain = mountPoint();
    renderListingList(asRoot(plain), [], {}, () => {});
    expect(plain.find((element) => element.className === "empty")?.textContent).toContain("İlk ilanı sen ver");

    const filtered = mountPoint();
    renderListingList(asRoot(filtered), [], { q: "masa" }, () => {});
    expect(filtered.find((element) => element.className === "empty")?.textContent).toContain("filtreye uyan");
  });
});

describe("listings view — filtering", () => {
  const items = [
    listing({ id: "a", title: "Ceviz masa", category: "ev", price: 250000 }),
    listing({ id: "b", title: "Bisiklet", body: "Şehir bisikleti", category: "diger", price: null }),
    listing({ id: "c", title: "Masa lambası", category: "ev", price: 45000 }),
  ];

  function view() {
    const mount = mountPoint();
    const onOpen = vi.fn();
    const instance = createListingsView(asRoot(mount), { onOpen });
    instance.setItems(items);
    return { mount, instance, onOpen };
  }

  it("renders every row and a tabular count", () => {
    const { mount } = view();
    expect(mount.findAll((element) => element.className === "listing")).toHaveLength(3);
    expect(mount.find((element) => element.className === "listings-count")?.textContent).toBe("3 ilan");
  });

  it("narrows on a search term as it is typed", () => {
    const { mount } = view();
    const search = mount.find(byField("q"));
    expect(search).toBeDefined();
    if (!search) return;

    search.value = "masa";
    search.fire("input");

    expect(mount.findAll((element) => element.className === "listing")).toHaveLength(2);
    expect(mount.find((element) => element.className === "listings-count")?.textContent).toBe("2 ilan");
  });

  it("narrows on a category", () => {
    const { mount } = view();
    const select = mount.find(byField("category"));
    expect(select).toBeDefined();
    if (!select) return;

    select.value = "ev";
    select.fire("change");

    const rows = mount.findAll((element) => element.className === "listing");
    expect(rows).toHaveLength(2);
    expect(rows.map((row) => row.find((element) => element.className === "listing-title")?.textContent)).toEqual([
      "Ceviz masa",
      "Masa lambası",
    ]);
  });

  it("drops barter listings as soon as a price bound is set", () => {
    const { mount } = view();
    const min = mount.find(byField("min"));
    expect(min).toBeDefined();
    if (!min) return;

    min.value = "1.000";
    min.fire("input");

    const rows = mount.findAll((element) => element.className === "listing");
    expect(rows).toHaveLength(1);
    expect(rows[0]?.dataset.id).toBe("a");
  });

  it("collapses the filter body on mobile and reports it through aria-expanded", () => {
    const { mount } = view();
    const toggle = mount.find(byRole("filters-toggle"));
    const body = mount.find((element) => element.className.startsWith("listings-filters-body"));
    expect(toggle).toBeDefined();
    expect(body).toBeDefined();
    if (!toggle || !body) return;

    expect(body.className).toBe("listings-filters-body is-collapsed");
    expect(toggle.getAttribute("aria-expanded")).toBe("false");

    toggle.click();

    expect(body.className).toBe("listings-filters-body is-open");
    expect(toggle.getAttribute("aria-expanded")).toBe("true");
  });
});

/* ------------------------------------------------------------------ detay */

describe("listing detail", () => {
  it("shows title, body, price, day and the 1:1 bridge", () => {
    const root = mountPoint();
    const onMessage = vi.fn();
    renderListingDetail(asRoot(root), listing(), { onMessage });

    expect(root.find((element) => element.className === "detail-title")?.textContent).toBe("Ceviz masa");
    expect(root.find((element) => element.className === "detail-body")?.textContent).toBe("Altı kişilik, sağlam.");
    expect(root.find((element) => element.className === "detail-day")?.textContent).toBe("2026-11-20");

    const message = root.find(byRole("message"));
    expect(message?.textContent).toBe("Mesaj gönder");
    message?.click();
    expect(onMessage).toHaveBeenCalledTimes(1);
  });

  it("draws no close button when the owner token is absent", () => {
    const root = mountPoint();
    renderListingDetail(asRoot(root), listing(), {});
    expect(root.find(byRole("close"))).toBeUndefined();
    expect(root.text()).not.toContain("İlanı kapat");
  });

  it("draws the close button for the owner and reports the click", () => {
    const root = mountPoint();
    const onClose = vi.fn();
    renderListingDetail(asRoot(root), listing(), { ownerToken: "tok-1", onClose });

    const close = root.find(byRole("close"));
    expect(close?.textContent).toBe("İlanı kapat");
    close?.click();
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it("treats a blank owner token as not the owner", () => {
    const root = mountPoint();
    renderListingDetail(asRoot(root), listing(), { ownerToken: "   " });
    expect(root.find(byRole("close"))).toBeUndefined();
  });

  it("keeps markup in a body as text", () => {
    const root = mountPoint();
    renderListingDetail(asRoot(root), listing({ body: "<script>alert(1)</script>" }), {});
    const body = root.find((element) => element.className === "detail-body");
    expect(body?.textContent).toBe("<script>alert(1)</script>");
    expect(body?.children).toHaveLength(0);
  });

  it("writes bilinmiyor when the day is missing", () => {
    const root = mountPoint();
    renderListingDetail(asRoot(root), listing({ day: "" }), {});
    expect(root.find((element) => element.className === "detail-day")?.textContent).toBe("bilinmiyor");
  });

  it("opens the detail from the list and hides the list panel", () => {
    const mount = mountPoint();
    const instance = createListingsView(asRoot(mount));
    instance.setItems([listing()]);

    const row = mount.find((element) => element.className === "listing");
    row?.click();

    expect(mount.find((element) => element.className === "listing-detail")).toBeDefined();
    const panels = mount.findAll((element) => element.dataset.panel !== undefined);
    const list = panels.find((element) => element.dataset.panel === "list");
    const detail = panels.find((element) => element.dataset.panel === "detail");
    expect(list?.hidden).toBe(true);
    expect(detail?.hidden).toBe(false);
  });
});

/* ------------------------------------------------------------------- form */

describe("listing form", () => {
  function compose(initial = {}) {
    const mount = mountPoint();
    const onPublish = vi.fn();
    const instance = createListingsView(asRoot(mount), { onPublish });
    instance.showCompose();
    const form = mount.find((element) => element.className === "listing-form");
    expect(form).toBeDefined();
    return { mount, form: form as FakeElement, onPublish, initial };
  }

  it("counts title and body as they are typed, and marks an overrun in words", () => {
    const { form } = compose();
    const title = form.find(byField("title"));
    const counter = form.find((element) => element.dataset.counter === "title");
    expect(title).toBeDefined();
    expect(counter).toBeDefined();
    if (!title || !counter) return;

    title.value = "Masa";
    title.fire("input");
    expect(counter.textContent).toBe("4/120");

    title.value = "x".repeat(MAX_TITLE + 1);
    title.fire("input");
    expect(counter.className).toBe("counter over");
  });

  it("refuses a title one character over the limit without echoing it", () => {
    const { mount, form, onPublish } = compose();
    const title = form.find(byField("title"));
    const body = form.find(byField("body"));
    const category = form.find(byField("category"));
    if (!title || !body || !category) return;

    title.value = `GİZLİ-BAŞLIK ${"a".repeat(MAX_TITLE)}`;
    title.fire("input");
    body.value = "gövde";
    body.fire("input");
    category.value = "ev";
    category.fire("change");

    form.fire("submit");

    const error = form.find((element) => element.dataset.error === "title");
    expect(error?.textContent).toContain("Başlık");
    // Neden + sıradaki adım: DESIGN.md hata kopyası.
    expect(error?.textContent).toContain("Kısalt");
    expect(error?.textContent).not.toContain("GİZLİ");
    expect(title.getAttribute("aria-invalid")).toBe("true");
    expect(onPublish).not.toHaveBeenCalled();
  });

  it("names the next step when no category is chosen", () => {
    const { form, onPublish } = compose();
    const title = form.find(byField("title"));
    const body = form.find(byField("body"));
    if (!title || !body) return;

    title.value = "Masa";
    title.fire("input");
    body.value = "gövde";
    body.fire("input");

    form.fire("submit");

    const error = form.find((element) => element.dataset.error === "category");
    expect(error?.textContent).toContain("Kategori");
    expect(error?.textContent).toContain("Listeden seç");
    expect(onPublish).not.toHaveBeenCalled();
  });

  it("refuses a body one character over the limit", () => {
    const { mount, form, onPublish } = compose();
    const title = form.find(byField("title"));
    const body = form.find(byField("body"));
    const category = form.find(byField("category"));
    if (!title || !body || !category) return;

    title.value = "Masa";
    title.fire("input");
    body.value = "x".repeat(MAX_BODY + 1);
    body.fire("input");
    category.value = "ev";
    category.fire("change");

    form.fire("submit");

    const error = form.find((element) => element.dataset.error === "body");
    expect(error?.textContent).toContain("Gövde");
    expect(error?.textContent).not.toContain("xxxx");
    expect(onPublish).not.toHaveBeenCalled();
  });

  it("refuses a price it cannot read, and never repeats the text", () => {
    const { mount, form, onPublish } = compose();
    const title = form.find(byField("title"));
    const body = form.find(byField("body"));
    const category = form.find(byField("category"));
    const price = form.find(byField("price"));
    if (!title || !body || !category || !price) return;

    title.value = "Masa";
    title.fire("input");
    body.value = "gövde";
    body.fire("input");
    category.value = "ev";
    category.fire("change");
    price.value = "12.34";
    price.fire("input");

    form.fire("submit");

    const error = form.find((element) => element.dataset.error === "price");
    expect(error?.textContent).toContain("Fiyat");
    expect(error?.textContent).not.toContain("12.34");
    expect(onPublish).not.toHaveBeenCalled();
  });

  it("publishes a valid listing with kuruş and the canonical category", () => {
    const { mount, form, onPublish } = compose();
    const title = form.find(byField("title"));
    const body = form.find(byField("body"));
    const category = form.find(byField("category"));
    const price = form.find(byField("price"));
    if (!title || !body || !category || !price) return;

    title.value = "  Ceviz masa  ";
    title.fire("input");
    body.value = "Altı kişilik.";
    body.fire("input");
    category.value = "ev";
    category.fire("change");
    price.value = "2.500,50";
    price.fire("input");

    form.fire("submit");

    expect(onPublish).toHaveBeenCalledWith({
      title: "Ceviz masa",
      body: "Altı kişilik.",
      price: 250050,
      category: "ev",
    });
    expect(form.find((element) => element.dataset.error === "title")?.textContent).toBe("");
  });

  it("publishes takas when the barter box is ticked, whatever is in the price field", () => {
    const { mount, form, onPublish } = compose();
    const title = form.find(byField("title"));
    const body = form.find(byField("body"));
    const category = form.find(byField("category"));
    const takas = form.find(byField("takas"));
    const price = form.find(byField("price"));
    if (!title || !body || !category || !takas || !price) return;

    title.value = "Bisiklet";
    title.fire("input");
    body.value = "Takas olur.";
    body.fire("input");
    category.value = "diger";
    category.fire("change");
    price.value = "999";
    price.fire("input");
    takas.checked = true;
    takas.fire("change");

    expect(price.disabled).toBe(true);

    form.fire("submit");

    expect(onPublish).toHaveBeenCalledWith({
      title: "Bisiklet",
      body: "Takas olur.",
      price: null,
      category: "diger",
    });
  });

  it("reports an empty title and body together, and lists no category as missing", () => {
    const fields = { ...emptyComposeFields(), title: "", body: "", price: "10", category: "" };
    const result = draftFromFields(fields);

    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.issues.map((issue) => issue.field)).toEqual(["title", "body", "category"]);
  });

  it("accepts the limits exactly and refuses one past them", () => {
    const ok = draftFromFields({
      title: "a".repeat(MAX_TITLE),
      body: "b".repeat(MAX_BODY),
      price: "",
      takas: true,
      category: "ev",
    });
    expect(ok.ok).toBe(true);

    const over = draftFromFields({
      title: "a".repeat(MAX_TITLE + 1),
      body: "b",
      price: "",
      takas: true,
      category: "ev",
    });
    expect(over.ok).toBe(false);
  });
});