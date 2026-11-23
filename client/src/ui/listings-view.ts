/**
 * Listings surface — Operate.
 *
 * A listing is permanent and public, so the claim it makes is a narrow one:
 * there is no account, IP or e-mail behind it. Its shape in the interface is a
 * single absence — no seller block, because there is no seller field. Both
 * `renderListingDetail` and the row read only the fields `ListingItem`
 * declares.
 *
 * Every string goes in through `textContent`. The body is foreign input; there
 * is no `innerHTML` in this file.
 *
 * Three panels in one shell: list (filter bar plus rows), detail, form. No
 * network call — publishing, the 1:1 bridge and closing a listing are handed
 * to the caller.
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

/** Ownership header. Non-empty means the listing belongs to this device. */
export const OWNER_HEADER = "x-zifiri-owner";

const ISO_DAY = /^\d{4}-\d{2}-\d{2}$/;

function count(text: string): number {
  return [...text].length;
}

/**
 * Ownership is a string, not a flag: if the header is missing, empty or only
 * whitespace, the listing does not belong to this device and "Close listing"
 * is never drawn.
 */
export function hasOwnerToken(token: string | null | undefined): boolean {
  return typeof token === "string" && token.trim().length > 0;
}

/* ------------------------------------------------------------------ price */

export type PriceParse = { readonly ok: true; readonly cents: number | null } | { readonly ok: false };

/**
 * English spelling: "," groups thousands, "." is the decimal point.
 * "1,250.50" → 125050. An empty field means trade (null); invalid text is an
 * error. At most two decimals; "12.34" reads as twelve point three four.
 */
const PRICE_SHAPE = /^(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d{1,2})?$/;

export function parsePrice(text: string): PriceParse {
  const raw = text.replace(/[\s\u00a0\u20ba]/g, "").replace(/tl$/i, "");
  if (raw === "") return { ok: true, cents: null };
  if (!PRICE_SHAPE.test(raw)) return { ok: false };

  const parts = raw.split(".");
  const whole = parts[0] ?? "0";
  const frac = parts[1] ?? "";
  const lira = Number(whole.replace(/,/g, ""));
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

/** A bound that does not parse is silently dropped; the filter never widens. */
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

/** Emptiness is information: it says why it is empty in one sentence. */
export function emptyMessage(active: boolean): string {
  return active ? "No listing matches this filter. Loosen it." : "No listings yet. Post the first one.";
}

/** The bar folds on mobile; on desktop the class is ignored (CSS). */
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
  back.textContent = "Back";
  back.addEventListener("click", () => options.onBack?.());
  article.append(back);

  const title = doc.createElement("h3");
  title.className = "detail-title";
  title.textContent = item.title;
  article.append(title);

  const meta = doc.createElement("p");
  meta.className = "detail-meta";

  const price = doc.createElement("span");
  price.className = item.price === null ? "listing-price trade" : "listing-price";
  price.textContent = formatPrice(item.price, item.currency);

  const chip = doc.createElement("span");
  chip.className = "chip";
  chip.textContent = categoryLabel(item.category);

  const day = doc.createElement("time");
  day.className = "detail-day";
  const dayText = item.day.trim();
  day.textContent = dayText === "" ? "unknown" : dayText;
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
  message.textContent = "Send message";
  message.addEventListener("click", () => options.onMessage?.(item));
  actions.append(message);

  // Drawn only for the owner. Otherwise there is no button — not hidden, absent.
  if (hasOwnerToken(options.ownerToken)) {
    const close = doc.createElement("button");
    close.type = "button";
    close.className = "btn-danger";
    close.dataset.role = "close";
    close.textContent = "Close listing";
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
  trade: boolean;
  category: string;
}

export function emptyComposeFields(): ComposeFields {
  return { title: "", body: "", price: "", trade: false, category: "" };
}

export type DraftBuild = { readonly ok: true; readonly value: ListingValue } | { readonly ok: false; readonly issues: readonly ListingIssue[] };

/**
 * A validated listing from the form fields. The price field is text; it is
 * turned into cents here, then `composeListing` runs as the single authority.
 * Error copy never echoes the input (see `composeListing`).
 */
export function draftFromFields(fields: ComposeFields): DraftBuild {
  const issues: ListingIssue[] = [];
  let price: number | null = null;

  if (!fields.trade) {
    const parsed = parsePrice(fields.price);
    if (!parsed.ok) {
      issues.push({
        field: "price",
        code: "not_a_number",
        message: "Price must be a number. Tick trade if you want to trade.",
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

  // An unreadable price blocks publication: falling back to trade would ignore
  // what the writer typed.
  if (issues.length > 0) return { ok: false, issues };
  if (composed.ok) return { ok: true, value: composed.value };
  return { ok: false, issues: composed.issues };
}

/**
 * Error copy: the reason in one sentence, the next step in another.
 * `composeListing` names the reason; the step is added here, because the step
 * belongs to the surface (the same reason may want another exit elsewhere).
 */
const NEXT_STEP: Record<string, string> = {
  empty: "Fill it in.",
  too_long: "Shorten it.",
  not_a_number: "Type a number, or tick trade.",
  negative: "Enter zero or more.",
  unknown_category: "Pick one from the list.",
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

  // Title — the counter makes the limit visible without blocking: pasted text
  // is not cut, the limit is reported once it is crossed.
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

  field("Title", "title", title).append(titleCount);

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

  field("Body", "body", body).append(bodyCount);

  const price = doc.createElement("input");
  price.type = "text";
  price.className = "field-input";
  price.value = fields.price;
  price.dataset.field = "price";
  price.setAttribute("inputmode", "decimal");
  price.setAttribute("autocomplete", "off");
  price.setAttribute("placeholder", "0.00");
  price.addEventListener("input", () => {
    fields.price = price.value;
  });

  const trade = doc.createElement("input");
  trade.type = "checkbox";
  trade.className = "field-check";
  trade.dataset.field = "trade";
  trade.checked = fields.trade;

  const tradeLabel = doc.createElement("label");
  tradeLabel.className = "field-check-label";
  const tradeText = doc.createElement("span");
  tradeText.textContent = "Trade";
  tradeLabel.append(trade, tradeText);

  const applyTrade = (): void => {
    fields.trade = trade.checked;
    price.disabled = trade.checked;
  };
  trade.addEventListener("change", applyTrade);
  applyTrade();

  const priceLabel = doc.createElement("label");
  priceLabel.className = "field";
  const priceCaption = doc.createElement("span");
  priceCaption.className = "field-label";
  priceCaption.textContent = "Price ($)";
  priceLabel.append(priceCaption, price);
  inputs.set("price", price);
  form.append(priceLabel, errorFor("price"));

  // Trade sits on its own row, outside the price label: a label inside a label
  // is invalid, and one sentence says what ticking it does.
  const tradeHint = doc.createElement("span");
  tradeHint.className = "field-hint";
  tradeHint.textContent = "The price field closes.";

  const tradeRow = doc.createElement("div");
  tradeRow.className = "field-row";
  tradeRow.append(tradeLabel, tradeHint);
  form.append(tradeRow);

  const category = doc.createElement("select");
  category.className = "field-input";
  category.dataset.field = "category";

  const blank = doc.createElement("option");
  blank.value = "";
  blank.textContent = "Choose a category";
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

  field("Category", "category", category);

  const actions = doc.createElement("div");
  actions.className = "detail-actions";

  const submit = doc.createElement("button");
  submit.type = "submit";
  submit.className = "btn-primary";
  submit.dataset.role = "publish";
  submit.textContent = "Publish listing";

  const cancel = doc.createElement("button");
  cancel.type = "button";
  cancel.className = "btn-quiet";
  cancel.dataset.role = "cancel";
  cancel.textContent = "Cancel";
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

/* ------------------------------------------------------------------- shell */

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
  heading.textContent = "Listings";

  const newButton = doc.createElement("button");
  newButton.type = "button";
  newButton.className = "btn-primary";
  newButton.dataset.role = "new";
  newButton.textContent = "New listing";

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
  toggle.textContent = "Filter";

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
  search.setAttribute("placeholder", "Title or body");
  search.addEventListener("input", () => {
    filter.q = search.value;
    refresh();
  });

  const category = doc.createElement("select");
  category.className = "field-input";
  category.dataset.field = "category";
  const all = doc.createElement("option");
  all.value = "";
  all.textContent = "All categories";
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
  min.setAttribute("placeholder", "Min");
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
  max.setAttribute("placeholder", "Max");
  max.addEventListener("input", () => {
    filter.max = max.value;
    refresh();
  });

  filterBody.append(
    filterField("Search", "q", search),
    filterField("Category", "category", category),
    filterField("Min price", "min", min),
    filterField("Max price", "max", max),
  );

  toggle.addEventListener("click", () => {
    const open = filterBody.className.includes("is-open") === false;
    filterBody.className = filtersBodyClass(open);
    toggle.setAttribute("aria-expanded", open ? "true" : "false");
    toggle.textContent = open ? "Close filters" : "Filter";
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
    countLine.textContent = visible.length === 1 ? "1 listing" : `${visible.length} listings`;
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
