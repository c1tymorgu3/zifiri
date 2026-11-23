/**
 * The application shell: one rail, three surfaces, one identity (`docs/spec.md`).
 *
 * Layout is the design's, not this module's: a 96px rail of icon-plus-label
 * items on desktop, the same markup as a bottom tab bar on a phone. The CSS
 * moves the rail; the DOM never changes shape, so the tab order and the
 * keyboard shortcuts stay identical at every width.
 *
 * Four deliberate constraints:
 *
 *  - Amber marks exactly one thing: the surface you are on. A second amber
 *    element in the rail would turn the accent into decoration, and the design
 *    allows one per region.
 *  - The identity indicator is a fingerprint, not a name. Eight characters in
 *    mono, top right; the full string and its copy button belong to the
 *    identity panel it opens.
 *  - `1` / `2` / `3` navigate, but never while the writer is typing. A shortcut
 *    that fires inside the composer deletes a half-written message.
 *  - Everything is built with `createElement` and `textContent`; there is no
 *    `innerHTML` here and nothing to escape. No storage is read or written: the
 *    active surface is the caller's state, not the browser's.
 */

import "./styles/shell.css";

export type SurfaceId = "rooms" | "messages" | "listings";

export interface Surface {
  readonly id: SurfaceId;
  readonly label: string;
}

/** The three surfaces, in rail order; the index is also the shortcut. */
export const SURFACES: readonly Surface[] = [
  { id: "rooms", label: "Odalar" },
  { id: "messages", label: "Mesajlar" },
  { id: "listings", label: "İlanlar" },
];

export interface Identity {
  /** The `zifiri1...` string; only the first eight characters are shown here. */
  readonly fingerprint: string;
}

export type ShellErrorCode =
  | "no_document"
  | "no_surfaces"
  | "duplicate_surface"
  | "unknown_surface"
  | "unknown_active";

export class ShellError extends Error {
  override name = "ShellError";

  constructor(
    message: string,
    readonly code: ShellErrorCode,
  ) {
    super(message);
  }
}

export interface ShellOptions {
  /** Defaults to {@link SURFACES}; pass your own to reorder or rename. */
  readonly surfaces?: readonly Surface[];
  readonly active: SurfaceId;
  readonly onNavigate: (id: SurfaceId) => void;
  readonly identity?: Identity | null;
  /** Opens the identity panel; without it the chip is a read-only indicator. */
  readonly onIdentity?: () => void;
  /** A small honest label next to the identity, e.g. "örnek veri" in demo. */
  readonly badge?: string | null;
}

export interface Shell {
  /** The shell element itself, inside the node you handed in. */
  readonly root: HTMLElement;
  readonly nav: HTMLElement;
  /** The top strip: demo badge and identity chip, right-aligned. */
  readonly topbar: HTMLElement;
  /** Where the active surface renders; `setContent` owns its children. */
  readonly main: HTMLElement;
  active(): SurfaceId;
  setActive(id: SurfaceId): void;
  setIdentity(identity: Identity | null): void;
  setContent(node: Node | null): void;
  destroy(): void;
}

const SVG_NS = "http://www.w3.org/2000/svg";

/** Eight characters is the fingerprint; a longer string is truncated, never wrapped. */
export const FINGERPRINT_LENGTH = 8;

/**
 * Icons are drawn, not typed: one 20px box, 1.5px stroke, `currentColor`.
 * An emoji or a Unicode glyph would render in whatever font the OS picked and
 * would be announced as a character to a screen reader.
 */
const ICON_PATHS: Record<SurfaceId, readonly string[]> = {
  // Three rules, the last one short: a list, not a speech bubble.
  rooms: ["M3.5 6h13", "M3.5 10h13", "M3.5 14h8"],
  // An envelope: the surface is private messages, not a chat room.
  messages: ["M3.25 5.5h13.5v9H3.25z", "m3.5 6 6.5 4.6L16.5 6"],
  // A notice with two lines of type: a listing.
  listings: ["M3.5 4.5h13v11h-13z", "M6.5 8h7", "M6.5 11h4"],
};

const FALLBACK_ICON: readonly string[] = ["M3.5 4.5h13v11h-13z"];

function drawIcon(doc: Document, id: SurfaceId): SVGElement {
  const svg = doc.createElementNS(SVG_NS, "svg");
  svg.setAttribute("class", "zf-tab-icon");
  svg.setAttribute("viewBox", "0 0 20 20");
  svg.setAttribute("width", "20");
  svg.setAttribute("height", "20");
  svg.setAttribute("fill", "none");
  svg.setAttribute("stroke", "currentColor");
  svg.setAttribute("stroke-width", "1.5");
  svg.setAttribute("stroke-linejoin", "round");
  svg.setAttribute("aria-hidden", "true");
  svg.setAttribute("focusable", "false");

  for (const d of ICON_PATHS[id] ?? FALLBACK_ICON) {
    const path = doc.createElementNS(SVG_NS, "path");
    path.setAttribute("d", d);
    svg.append(path);
  }

  return svg;
}

function span(doc: Document, className: string, text: string): HTMLSpanElement {
  const node = doc.createElement("span");
  node.className = className;
  node.textContent = text;
  return node;
}

/** A keypress inside a field is text, never a command. */
function isEditable(target: EventTarget | null): boolean {
  if (target === null || typeof (target as Element).tagName !== "string") return false;
  const element = target as HTMLElement;
  const tag = element.tagName;
  return tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" || element.isContentEditable === true;
}

function assertSurfaces(surfaces: readonly Surface[]): void {
  if (surfaces.length === 0) {
    throw new ShellError("en az bir yüzey gerekir", "no_surfaces");
  }

  const seen = new Set<string>();
  for (const surface of surfaces) {
    if (seen.has(surface.id)) {
      throw new ShellError(`yüzey iki kez tanımlı: ${surface.id}`, "duplicate_surface");
    }
    seen.add(surface.id);
  }
}

let shellCount = 0;

/**
 * Builds the rail and the content column inside `root`, replacing whatever was
 * there. Returns a handle; the caller owns navigation state and tells the shell
 * which surface is active.
 */
export function renderShell(root: HTMLElement, options: ShellOptions): Shell {
  const doc = root.ownerDocument ?? (typeof document === "undefined" ? null : document);
  if (doc === null) throw new ShellError("renderShell bir belge gerektirir", "no_document");

  const surfaces = options.surfaces ?? SURFACES;
  assertSurfaces(surfaces);

  const initial = surfaces.find((surface) => surface.id === options.active);
  if (initial === undefined) {
    throw new ShellError(`bilinmeyen yüzey: ${options.active}`, "unknown_active");
  }

  shellCount += 1;
  const contentId = `zf-content-${shellCount}`;
  let current: SurfaceId = initial.id;

  const shell = doc.createElement("div");
  shell.className = "zf-shell";
  shell.setAttribute("data-active", current);

  // A keyboard user lands here first and skips the rail without tabbing twice.
  const skip = doc.createElement("a");
  skip.className = "zf-skip";
  skip.setAttribute("href", `#${contentId}`);
  skip.textContent = "İçeriğe geç";

  const nav = doc.createElement("nav");
  nav.className = "zf-rail";
  nav.setAttribute("aria-label", "Yüzeyler");

  const list = doc.createElement("ul");
  list.className = "zf-rail-list";

  const buttons = new Map<SurfaceId, HTMLButtonElement>();

  const select = (id: SurfaceId): void => {
    if (id === current) return;
    const surface = surfaces.find((candidate) => candidate.id === id);
    if (surface === undefined) {
      throw new ShellError(`bilinmeyen yüzey: ${id}`, "unknown_surface");
    }
    setActive(surface.id);
    options.onNavigate(surface.id);
  };

  for (const [index, surface] of surfaces.entries()) {
    const slot = doc.createElement("li");
    slot.className = "zf-rail-slot";

    const button = doc.createElement("button");
    button.type = "button";
    button.className = "zf-tab";
    button.setAttribute("data-surface", surface.id);
    // Only the first nine surfaces have a key; past that the label is the path.
    if (index < 9) button.setAttribute("aria-keyshortcuts", String(index + 1));
    if (surface.id === current) button.setAttribute("aria-current", "page");

    button.append(drawIcon(doc, surface.id), span(doc, "zf-tab-label", surface.label));
    button.addEventListener("click", () => select(surface.id));

    buttons.set(surface.id, button);
    slot.append(button);
    list.append(slot);
  }

  nav.append(list);

  // The top strip is not a fourth destination: a wordmark, a badge and the
  // fingerprint. Its left half is the only place on the page that can say what
  // the page is; leaving it empty wastes the first thing a visitor reads.
  const topbar = doc.createElement("header");
  topbar.className = "zf-topbar";

  const brand = doc.createElement("div");
  brand.className = "zf-brand";
  brand.append(
    span(doc, "zf-brand-name", "zifiri"),
    span(doc, "zf-brand-line", "anonim tahta · hesap yok"),
  );
  topbar.append(brand);

  const badgeText = options.badge?.trim() ?? "";
  if (badgeText !== "") {
    const badge = span(doc, "zf-badge", badgeText);
    topbar.append(badge);
  }

  const identityBlock = doc.createElement(options.onIdentity === undefined ? "div" : "button");
  identityBlock.className = "zf-identity";
  identityBlock.setAttribute("data-state", "none");

  const identityLabel = span(doc, "zf-identity-label", "kimlik");
  const identityValue = span(doc, "zf-identity-value", "—");
  identityBlock.append(identityLabel, identityValue);

  if (options.onIdentity !== undefined) {
    (identityBlock as HTMLButtonElement).type = "button";
    identityBlock.setAttribute("aria-label", "kimliği aç");
    identityBlock.addEventListener("click", () => options.onIdentity?.());
  }

  topbar.append(identityBlock);

  const main = doc.createElement("main");
  main.className = "zf-main";
  main.setAttribute("id", contentId);
  main.setAttribute("tabindex", "-1");

  shell.append(skip, nav, topbar, main);
  root.replaceChildren(shell);

  const setIdentity = (identity: Identity | null): void => {
    const fingerprint = identity?.fingerprint.trim() ?? "";
    if (fingerprint === "") {
      identityValue.textContent = "—";
      identityBlock.setAttribute("data-state", "none");
      identityBlock.removeAttribute("title");
      return;
    }
    identityValue.textContent = fingerprint.slice(0, FINGERPRINT_LENGTH);
    identityBlock.setAttribute("data-state", "set");
    // The eight characters are a prefix; the title carries the rest so a
    // sighted user is not told a truncated string is the whole key.
    identityBlock.setAttribute("title", fingerprint);
  };

  function setActive(id: SurfaceId): void {
    if (!buttons.has(id)) {
      throw new ShellError(`bilinmeyen yüzey: ${id}`, "unknown_surface");
    }
    current = id;
    shell.setAttribute("data-active", id);
    for (const [surfaceId, button] of buttons) {
      if (surfaceId === id) button.setAttribute("aria-current", "page");
      else button.removeAttribute("aria-current");
    }
  }

  const onKeyDown = (event: KeyboardEvent): void => {
    if (event.defaultPrevented || event.altKey || event.ctrlKey || event.metaKey) return;
    if (isEditable(event.target)) return;

    const index = Number(event.key) - 1;
    if (!Number.isInteger(index) || index < 0 || index >= surfaces.length) return;

    const surface = surfaces[index];
    if (surface === undefined) return;

    event.preventDefault();
    select(surface.id);
  };

  doc.addEventListener("keydown", onKeyDown);
  setIdentity(options.identity ?? null);

  return {
    root: shell,
    nav,
    topbar,
    main,
    active: () => current,
    setActive,
    setIdentity,
    setContent(node: Node | null): void {
      if (node === null) main.replaceChildren();
      else main.replaceChildren(node);
    },
    destroy(): void {
      doc.removeEventListener("keydown", onKeyDown);
      shell.remove();
    },
  };
}
