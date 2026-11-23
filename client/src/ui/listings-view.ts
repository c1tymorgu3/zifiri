/**
 * İlanlar yüzeyi — Operate.
 *
 * Bir ilan kalıcı ve herkese açık; bu yüzden iddia dar: arkasında hesap, IP,
 * e-posta yok. Bunun arayüzdeki karşılığı tek bir yokluk — satıcı bloğu yok,
 * çünkü satıcı alanı yok. `renderListingDetail` de, satır da yalnız
 * `ListingItem`'ın bildirdiği alanları okur.
 *
 * Her metin `textContent` ile girer. Gövde yabancı girdidir; bu dosyada
 * `innerHTML` geçmez.
 *
 * Üç yüzey tek kabukta: liste (filtre çubuğu + satırlar), detay, form. Ağ
 * çağrısı yok — yayınlama, 1:1 köprüsü ve kapatma çağırana devredilir.
 */
import "../styles/listings.css";
import {
  CATEGORY_LABELS,
  LISTING_CATEGORIES,
  MAX_BODY,
  MAX_TITLE,
  categoryLabel,
  composeListing,
  filterListings,
  formatPrice,
  renderListings,
  type ListingFilter,
  type ListingIssue,
  type ListingItem,
  type ListingValue,
} from "./listings";

/** Sahiplik başlığı. Doluysa ilan bu cihaza ait; boşsa değil. */
export const OWNER_HEADER = "x-zifiri-owner";

const ISO_DAY = /^\d{4}-\d{2}-\d{2}$/;

function count(text: string): number {
  return [...text].length;
}

/**
 * Sahiplik bir dizedir, bir bayrak değil: başlık yoksa, boşsa ya da yalnız
 * boşluksa ilan bu cihaza ait değildir ve "İlanı kapat" hiç çizilmez.
 */
export function hasOwnerToken(token: string | null | undefined): boolean {
  return typeof token === "string" && token.trim().length > 0;
}

/* ------------------------------------------------------------------ fiyat */

export type PriceParse = { readonly ok: true; readonly cents: number | null } | { readonly ok: false };

/**
 * Türkçe yazım: "." binlik, "," kuruş. "1.250,50" → 125050. Boş alan takas
 * demektir (null), geçersiz metin hata. Virgülden sonra en fazla iki hane;
 * "12.34" reddedilir çünkü Türkçe okunuşu 1234 değil, belirsizdir.
 */
const PRICE_SHAPE = /^(?:\d{1,3}(?:\.\d{3})+|\d+)(?:,\d{1,2})?$/;

export function parsePrice(text: string): PriceParse {
  const raw = text.replace(/[\s\u00a0\u20ba]/g, "").replace(/tl$/i, "");
  if (raw === "") return { ok: true, cents: null };
  if (!PRICE_SHAPE.test(raw)) return { ok: false };

  const parts = raw.split(",");
  const whole = parts[0] ?? "0";
  const frac = parts[1] ?? "";
  const lira = Number(whole.replace(/\./g, ""));
  const kurus = Number(frac.padEnd(2, "0"));
  if (!Number.isSafeInteger(lira) || !Number.isSafeInteger(kurus)) return { ok: false };

  const cents = lira * 100 + kurus;
  return Number.isSafeInteger(cents) ? { ok: true, cents } : { ok: false };
}

/* ------------------------------------------------------------------ filtre */

export interface FilterForm {
  q: string;
  category: string;
  min: string;
  max: string;
}

export function emptyFilterForm(): FilterForm {
  return { q: "", category: "", min: "", max: "" };
}

/** Sınır alanları geçersizse sessizce yok sayılır; filtre genişlemez. */
export function filterFromForm(form: FilterForm): ListingFilter {
  const filter: ListingFilter = {};

  const q = form.q.trim();
  if (q !== "") filter.q = q;
  if (form.category.trim() !== "") filter.category = form.category;

  const min = parsePrice(form.min);
  if (min.ok && min.cents !== null) filter.minPrice = min.cents;

  const max = parsePrice(form.max);
  if (max.ok && max.cents !== null) filter.maxPrice = max.cents;

  return filter;
}

export function isFilterActive(filter: ListingFilter): boolean {
  return (
    filter.q !== undefined ||
    filter.category !== undefined ||
    filter.minPrice !== undefined ||
    filter.maxPrice !== undefined
  );
}

/** Boşluk bir bilgidir: neden boş olduğunu tek cümleyle söyler. */
export function emptyMessage(active: boolean): string {
  return active ? "Bu filtreye uyan ilan yok. Filtreyi gevşet." : "Henüz ilan yok. İlk ilanı sen ver.";
}

/** Mobilde çubuk katlanır; masaüstünde sınıf yok sayılır (CSS). */
export function filtersBodyClass(open: boolean): string {
  return `listings-filters-body ${open ? "is-open" : "is-collapsed"}`;
}

/* -------------------------------------------------------------------- liste */

export function renderListingList(
  root: HTMLElement,
  items: readonly ListingItem[],
  filter: ListingFilter,
  onOpen: (id: string) => void,
): void {
  if (items.length === 0) {
    const doc = root.ownerDocument;
    root.replaceChildren();
    const empty = doc.createElement("p");
    empty.className = "empty";
    empty.textContent = emptyMessage(isFilterActive(filter));
    root.append(empty);
    return;
  }

  renderListings(root, items, onOpen);
}

/* ------------------------------------------------------------------- detay */

export interface DetailOptions {
  ownerToken?: string | null;
  onMessage?: (item: ListingItem) => void;
  onClose?: (item: ListingItem) => void;
  onBack?: () => void;
}

export function renderListingDetail(
  root: HTMLElement,
  item: ListingItem,
  options: DetailOptions = {},
): void {
  const doc = root.ownerDocument;
  root.replaceChildren();

  const article = doc.createElement("article");
  article.className = "listing-detail";
  article.dataset.id = item.id;

  const back = doc.createElement("button");
  back.type = "button";
  back.className = "listing-back";
  back.dataset.role = "back";
  back.textContent = "Geri";
  back.addEventListener("click", () => options.onBack?.());
  article.append(back);

  const title = doc.createElement("h3");
  title.className = "detail-title";
  title.textContent = item.title;
  article.append(title);

  const meta = doc.createElement("p");
  meta.className = "detail-meta";

  const price = doc.createElement("span");
  price.className = item.price === null ? "listing-price takas" : "listing-price";
  price.textContent = formatPrice(item.price, item.currency);

  const chip = doc.createElement("span");
  chip.className = "chip";
  chip.textContent = categoryLabel(item.category);

  const day = doc.createElement("time");
  day.className = "detail-day";
  const dayText = item.day.trim();
  day.textContent = dayText === "" ? "bilinmiyor" : dayText;
  if (ISO_DAY.test(dayText)) day.setAttribute("datetime", dayText);

  meta.append(price, chip, day);
  article.append(meta);

  const body = doc.createElement("p");
  body.className = "detail-body";
  body.textContent = item.body;
  article.append(body);

  const actions = doc.createElement("div");
  actions.className = "detail-actions";

  const message = doc.createElement("button");
  message.type = "button";
  message.className = "btn-primary";
  message.dataset.role = "message";
  message.textContent = "Mesaj gönder";
  message.addEventListener("click", () => options.onMessage?.(item));
  actions.append(message);

  // Yalnız sahipse çizilir. Sahip değilse düğme yok — gizli değil, yok.
  if (hasOwnerToken(options.ownerToken)) {
    const close = doc.createElement("button");
    close.type = "button";
    close.className = "btn-danger";
    close.dataset.role = "close";
    close.textContent = "İlanı kapat";
    close.addEventListener("click", () => options.onClose?.(item));
    actions.append(close);
  }

  article.append(actions);
  root.append(article);
}

/* -------------------------------------------------------------------- form */

export interface ComposeFields {
  title: string;
  body: string;
  price: string;
  takas: boolean;
  category: string;
}

export function emptyComposeFields(): ComposeFields {
  return { title: "", body: "", price: "", takas: false, category: "" };
}

export type DraftBuild = { readonly ok: true; readonly value: ListingValue } | { readonly ok: false; readonly issues: readonly ListingIssue[] };

/**
 * Form alanlarından doğrulanmış bir ilan. Fiyat alanı metindir; burada
 * kuruşa çevrilir, sonra `composeListing` tek karar mercii olarak çalışır.
 * Hata metinleri girdiyi yansıtmaz (bkz. `composeListing`).
 */
export function draftFromFields(fields: ComposeFields): DraftBuild {
  const issues: ListingIssue[] = [];
  let price: number | null = null;

  if (!fields.takas) {
    const parsed = parsePrice(fields.price);
    if (!parsed.ok) {
      issues.push({
        field: "price",
        code: "not_a_number",
        message: "Fiyat sayı olmalı. Takas için takas seçeneğini işaretle.",
      });
    } else {
      price = parsed.cents;
    }
  }

  const composed = composeListing({
    title: fields.title,
    body: fields.body,
    price,
    category: fields.category,
  });

  // Fiyat okunamadıysa ilan yayınlanmaz: sessizce takasa düşmek, yazılanı
  // yok saymak olurdu.
  if (issues.length > 0) return { ok: false, issues };
  if (composed.ok) return { ok: true, value: composed.value };
  return { ok: false, issues: composed.issues };
}

/**
 * Error copy: the reason in one sentence, the next step in another.
 * `composeListing` nedeni söyler; adım burada eklenir, çünkü adım yüzeye
 * aittir (aynı neden başka yerde başka bir çıkış isteyebilir).
 */
const NEXT_STEP: Record<string, string> = {
  empty: "Doldur.",
  too_long: "Kısalt.",
  not_a_number: "Sayı yaz ya da takası işaretle.",
  negative: "Sıfır ya da üstü yaz.",
  unknown_category: "Listeden seç.",
};

export function withNextStep(issue: ListingIssue): string {
  const step = NEXT_STEP[issue.code];
  if (step === undefined || issue.message.includes(step)) return issue.message;
  return `${issue.message} ${step}`;
}

export interface ComposeFormOptions {
  initial?: Partial<ComposeFields>;
  onSubmit?: (value: ListingValue) => void;
  onCancel?: () => void;
}

export interface ComposeHandle {
  readonly form: HTMLFormElement;
  readonly fields: ComposeFields;
  validate(): readonly ListingIssue[];
}

export function renderComposeForm(root: HTMLElement, options: ComposeFormOptions = {}): ComposeHandle {
  const doc = root.ownerDocument;
  const fields: ComposeFields = { ...emptyComposeFields(), ...options.initial };
  const errors = new Map<string, HTMLElement>();
  const inputs = new Map<string, HTMLInputElement>();

  root.replaceChildren();

  const form = doc.createElement("form");
  form.className = "listing-form";
  form.setAttribute("novalidate", "");

  const errorFor = (field: string): HTMLElement => {
    const existing = errors.get(field);
    if (existing) return existing;
    const node = doc.createElement("p");
    node.className = "field-error";
    node.dataset.error = field;
    node.setAttribute("role", "alert");
    errors.set(field, node);
    return node;
  };

  const field = (
    labelText: string,
    name: string,
    control: HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement,
  ): HTMLElement => {
    const label = doc.createElement("label");
    label.className = "field";

    const caption = doc.createElement("span");
    caption.className = "field-label";
    caption.textContent = labelText;

    label.append(caption, control);
    inputs.set(name, control as HTMLInputElement);
    form.append(label, errorFor(name));
    return label;
  };

  // Başlık — sayaç sınırı görünür kılar, engellemez: yapıştırılan metin
  // kesilmez, sınır aşılınca söylenir.
  const title = doc.createElement("input");
  title.type = "text";
  title.className = "field-input";
  title.value = fields.title;
  title.dataset.field = "title";
  title.setAttribute("autocomplete", "off");
  title.setAttribute("spellcheck", "false");

  const titleCount = doc.createElement("span");
  titleCount.className = "counter";
  titleCount.dataset.counter = "title";

  const syncTitle = (): void => {
    const used = count(fields.title);
    titleCount.textContent = `${used}/${MAX_TITLE}`;
    titleCount.className = used > MAX_TITLE ? "counter over" : "counter";
  };
  title.addEventListener("input", () => {
    fields.title = title.value;
    syncTitle();
  });
  syncTitle();

  field("Başlık", "title", title).append(titleCount);

  const body = doc.createElement("textarea");
  body.className = "field-input field-area";
  body.value = fields.body;
  body.dataset.field = "body";
  body.setAttribute("rows", "6");
  body.setAttribute("spellcheck", "false");

  const bodyCount = doc.createElement("span");
  bodyCount.className = "counter";
  bodyCount.dataset.counter = "body";

  const syncBody = (): void => {
    const used = count(fields.body);
    bodyCount.textContent = `${used}/${MAX_BODY}`;
    bodyCount.className = used > MAX_BODY ? "counter over" : "counter";
  };
  body.addEventListener("input", () => {
    fields.body = body.value;
    syncBody();
  });
  syncBody();

  field("Gövde", "body", body).append(bodyCount);

  const price = doc.createElement("input");
  price.type = "text";
  price.className = "field-input";
  price.value = fields.price;
  price.dataset.field = "price";
  price.setAttribute("inputmode", "decimal");
  price.setAttribute("autocomplete", "off");
  price.setAttribute("placeholder", "0,00");
  price.addEventListener("input", () => {
    fields.price = price.value;
  });

  const takas = doc.createElement("input");
  takas.type = "checkbox";
  takas.className = "field-check";
  takas.dataset.field = "takas";
  takas.checked = fields.takas;

  const takasLabel = doc.createElement("label");
  takasLabel.className = "field-check-label";
  const takasText = doc.createElement("span");
  takasText.textContent = "Takas";
  takasLabel.append(takas, takasText);

  const applyTakas = (): void => {
    fields.takas = takas.checked;
    price.disabled = takas.checked;
  };
  takas.addEventListener("change", applyTakas);
  applyTakas();

  const priceLabel = doc.createElement("label");
  priceLabel.className = "field";
  const priceCaption = doc.createElement("span");
  priceCaption.className = "field-label";
  priceCaption.textContent = "Fiyat (₺)";
  priceLabel.append(priceCaption, price);
  inputs.set("price", price);
  form.append(priceLabel, errorFor("price"));

  // Takas kendi satırında, fiyat etiketinin dışında: etiket içinde etiket
  // olmaz, ve işaretlenince ne olacağı tek cümleyle yazılır.
  const takasHint = doc.createElement("span");
  takasHint.className = "field-hint";
  takasHint.textContent = "Fiyat alanı kapanır.";

  const takasRow = doc.createElement("div");
  takasRow.className = "field-row";
  takasRow.append(takasLabel, takasHint);
  form.append(takasRow);

  const category = doc.createElement("select");
  category.className = "field-input";
  category.dataset.field = "category";

  const blank = doc.createElement("option");
  blank.value = "";
  blank.textContent = "Kategori seç";
  category.append(blank);

  for (const slug of LISTING_CATEGORIES) {
    const option = doc.createElement("option");
    option.value = slug;
    option.textContent = CATEGORY_LABELS[slug];
    category.append(option);
  }
  category.value = fields.category;
  category.addEventListener("change", () => {
    fields.category = category.value;
  });

  field("Kategori", "category", category);

  const actions = doc.createElement("div");
  actions.className = "detail-actions";

  const submit = doc.createElement("button");
  submit.type = "submit";
  submit.className = "btn-primary";
  submit.dataset.role = "publish";
  submit.textContent = "İlanı yayınla";

  const cancel = doc.createElement("button");
  cancel.type = "button";
  cancel.className = "btn-quiet";
  cancel.dataset.role = "cancel";
  cancel.textContent = "Vazgeç";
  cancel.addEventListener("click", () => options.onCancel?.());

  actions.append(submit, cancel);
  form.append(actions);

  const validate = (): readonly ListingIssue[] => {
    for (const node of errors.values()) node.textContent = "";
    for (const input of inputs.values()) input.setAttribute("aria-invalid", "false");

    const result = draftFromFields(fields);
    if (result.ok) return [];

    for (const issue of result.issues) {
      const node = errorFor(issue.field);
      if (node.textContent === "") node.textContent = withNextStep(issue);
      inputs.get(issue.field)?.setAttribute("aria-invalid", "true");
    }
    return result.issues;
  };

  form.addEventListener("submit", (event) => {
    event?.preventDefault();
    const result = draftFromFields(fields);
    if (!result.ok) {
      validate();
      return;
    }
    validate();
    options.onSubmit?.(result.value);
  });

  root.append(form);

  return {
    form: form as HTMLFormElement,
    fields,
    validate,
  };
}

/* ------------------------------------------------------------------- kabuk */

export interface ListingsViewOptions {
  ownerToken?: string | null;
  onOpen?: (item: ListingItem) => void;
  onMessage?: (item: ListingItem) => void;
  onClose?: (item: ListingItem) => void;
  onPublish?: (value: ListingValue) => void;
}

export interface ListingsView {
  readonly element: HTMLElement;
  readonly filter: FilterForm;
  setItems(items: readonly ListingItem[]): void;
  setOwnerToken(token: string | null): void;
  showList(): void;
  showDetail(item: ListingItem): void;
  showCompose(): void;
}

export function createListingsView(mount: HTMLElement, options: ListingsViewOptions = {}): ListingsView {
  const doc = mount.ownerDocument;
  let items: readonly ListingItem[] = [];
  let ownerToken: string | null = options.ownerToken ?? null;
  const filter: FilterForm = emptyFilterForm();

  const surface = doc.createElement("section");
  surface.className = "listings-surface";

  const head = doc.createElement("header");
  head.className = "listings-head";

  const heading = doc.createElement("h2");
  heading.className = "listings-heading";
  heading.textContent = "İlanlar";

  const newButton = doc.createElement("button");
  newButton.type = "button";
  newButton.className = "btn-primary";
  newButton.dataset.role = "new";
  newButton.textContent = "İlan ver";

  head.append(heading, newButton);

  const listPanel = doc.createElement("div");
  listPanel.className = "listings-panel";
  listPanel.dataset.panel = "list";

  const filterBar = doc.createElement("form");
  filterBar.className = "listings-filters";
  filterBar.setAttribute("role", "search");

  const toggle = doc.createElement("button");
  toggle.type = "button";
  toggle.className = "listings-filters-toggle";
  toggle.dataset.role = "filters-toggle";
  toggle.setAttribute("aria-expanded", "false");
  toggle.textContent = "Filtre";

  const filterBody = doc.createElement("div");
  filterBody.className = filtersBodyClass(false);

  const filterField = (
    labelText: string,
    name: string,
    control: HTMLInputElement | HTMLSelectElement,
  ): HTMLElement => {
    const label = doc.createElement("label");
    label.className = "filter-field";
    const caption = doc.createElement("span");
    caption.className = "filter-label";
    caption.textContent = labelText;
    label.append(caption, control);
    return label;
  };

  const search = doc.createElement("input");
  search.type = "search";
  search.className = "field-input";
  search.dataset.field = "q";
  search.setAttribute("autocomplete", "off");
  search.setAttribute("placeholder", "Başlık ya da gövde");
  search.addEventListener("input", () => {
    filter.q = search.value;
    refresh();
  });

  const category = doc.createElement("select");
  category.className = "field-input";
  category.dataset.field = "category";
  const all = doc.createElement("option");
  all.value = "";
  all.textContent = "Tüm kategoriler";
  category.append(all);
  for (const slug of LISTING_CATEGORIES) {
    const option = doc.createElement("option");
    option.value = slug;
    option.textContent = CATEGORY_LABELS[slug];
    category.append(option);
  }
  category.addEventListener("change", () => {
    filter.category = category.value;
    refresh();
  });

  const min = doc.createElement("input");
  min.type = "text";
  min.className = "field-input";
  min.dataset.field = "min";
  min.setAttribute("inputmode", "decimal");
  min.setAttribute("autocomplete", "off");
  min.setAttribute("placeholder", "En az");
  min.addEventListener("input", () => {
    filter.min = min.value;
    refresh();
  });

  const max = doc.createElement("input");
  max.type = "text";
  max.className = "field-input";
  max.dataset.field = "max";
  max.setAttribute("inputmode", "decimal");
  max.setAttribute("autocomplete", "off");
  max.setAttribute("placeholder", "En çok");
  max.addEventListener("input", () => {
    filter.max = max.value;
    refresh();
  });

  filterBody.append(
    filterField("Ara", "q", search),
    filterField("Kategori", "category", category),
    filterField("En az fiyat", "min", min),
    filterField("En çok fiyat", "max", max),
  );

  toggle.addEventListener("click", () => {
    const open = filterBody.className.includes("is-open") === false;
    filterBody.className = filtersBodyClass(open);
    toggle.setAttribute("aria-expanded", open ? "true" : "false");
    toggle.textContent = open ? "Filtreyi kapat" : "Filtre";
  });

  filterBar.append(toggle, filterBody);

  const countLine = doc.createElement("p");
  countLine.className = "listings-count";
  countLine.setAttribute("role", "status");
  countLine.setAttribute("aria-live", "polite");

  const listRoot = doc.createElement("div");
  listRoot.className = "listings-list";

  listPanel.append(filterBar, countLine, listRoot);

  const detailPanel = doc.createElement("div");
  detailPanel.className = "listings-panel";
  detailPanel.dataset.panel = "detail";
  detailPanel.hidden = true;

  const composePanel = doc.createElement("div");
  composePanel.className = "listings-panel";
  composePanel.dataset.panel = "compose";
  composePanel.hidden = true;

  surface.append(head, listPanel, detailPanel, composePanel);
  mount.append(surface);

  const refresh = (): void => {
    const active = filterFromForm(filter);
    const visible = filterListings(items, active);
    countLine.textContent = `${visible.length} ilan`;
    renderListingList(listRoot, visible, active, (id) => {
      const item = items.find((candidate) => candidate.id === id);
      if (item) view.showDetail(item);
    });
  };

  const showPanel = (panel: HTMLElement): void => {
    for (const candidate of [listPanel, detailPanel, composePanel]) {
      candidate.hidden = candidate !== panel;
    }
  };

  const view: ListingsView = {
    element: surface,
    filter,
    setItems(next: readonly ListingItem[]): void {
      items = next;
      refresh();
    },
    setOwnerToken(token: string | null): void {
      ownerToken = token;
    },
    showList(): void {
      showPanel(listPanel);
    },
    showDetail(item: ListingItem): void {
      renderListingDetail(detailPanel, item, {
        ownerToken,
        onBack: () => view.showList(),
        onMessage: (target) => options.onMessage?.(target),
        onClose: (target) => options.onClose?.(target),
      });
      options.onOpen?.(item);
      showPanel(detailPanel);
    },
    showCompose(): void {
      renderComposeForm(composePanel, {
        onSubmit: (value) => options.onPublish?.(value),
        onCancel: () => view.showList(),
      });
      showPanel(composePanel);
    },
  };

  newButton.addEventListener("click", () => view.showCompose());
  refresh();

  return view;
}
