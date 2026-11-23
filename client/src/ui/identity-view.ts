/**
 * Identity surface: the backup line, its fingerprint, import, and the danger
 * zone that makes the identity disappear.
 *
 * The copy is the design here. `docs/spec.md` asks for the `zifiri1...` string in
 * mono, an 8-character fingerprint, a copy button, and one sentence —
 * "If you lose this line, your identity is gone." — and the danger zone is a
 * `--danger` border with a phrase typed by hand, not a red button with a
 * trash icon. Nothing in this module decorates danger; it only gates it.
 *
 * Two invariants are load-bearing:
 *
 *  - An import failure never repeats the input. A pasted seed can be one
 *    character off, and echoing it into a status line would put half a secret
 *    on screen and into any screenshot. Every message below is fixed text.
 *  - "Vanish" is two steps and no undo: arm, then type the phrase. The
 *    callback fires once; after that the control is spent.
 */
import {
  BODY_LENGTH,
  EXPORT_PREFIX,
  LEGACY_EXPORT_PREFIX,
  LINE_LENGTH,
  exportIdentity,
  importIdentity,
  type Identity,
  type ImportedIdentity,
} from "../identity";
import "../styles/identity.css";
import { sha256 } from "@noble/hashes/sha2.js";

/** The design: an 8-character fingerprint, not the 13 of a peer id. */
export const FINGERPRINT_LENGTH = 8;

const BASE32_ALPHABET = "abcdefghijklmnopqrstuvwxyz234567";

/** The exact phrase, lower case. Matching tolerates case and spacing. */
export const VANISH_PHRASE = "vanish";

export const LOST_WARNING = "If you lose this line, your identity is gone.";

export type DangerStep = "idle" | "armed" | "confirmed";

export type ImportCode =
  | "empty"
  | "prefix"
  | "charset"
  | "length"
  | "checksum"
  | "unreadable";

export type ImportResult =
  | { ok: true; state: IdentityViewState }
  | { ok: false; code: ImportCode; message: string };

export type VanishReason = "no-identity" | "not-armed" | "phrase" | "done" | "failed";

export type VanishOutcome = { ok: true } | { ok: false; reason: VanishReason };

export interface IdentityViewState {
  readonly kind: "none" | "ready";
  /** The full `zifiri1...` line, or null when no identity is loaded. */
  readonly line: string | null;
  /** 8 base32 characters, or null. */
  readonly fingerprint: string | null;
  readonly nextI: number | null;
  readonly danger: DangerStep;
  /** True once the vanish callback has run. The control cannot fire twice. */
  readonly vanished: boolean;
}

export interface IdentityViewOptions {
  /** Panel renders inside this element. Omit it for the DOM-free core. */
  mount?: HTMLElement | null;
  /** Runs once, after the typed phrase is confirmed. */
  onVanish?: () => void | Promise<void>;
  /** Clipboard seam; defaults to `navigator.clipboard.writeText`. */
  copy?: (text: string) => Promise<void>;
}

export interface IdentityView {
  /** Loads a seed directly (the normal path: identity was just created). */
  show(seed: Uint8Array, nextI: number, generation?: number): void;
  /** Loads a backup line. Failures carry fixed copy, never the input. */
  importLine(text: string): ImportResult;
  /** Copies the line. False when there is nothing to copy or the copy failed. */
  copyLine(): Promise<boolean>;
  line(): string | null;
  fingerprint(): string | null;
  state(): IdentityViewState;
  /** Step one: reveal the typed confirmation. */
  armVanish(): boolean;
  /** Step two: the phrase decides. Irreversible once it returns ok. */
  confirmVanish(phrase: string): Promise<VanishOutcome>;
  cancelVanish(): void;
}

/**
 * base32(sha256(seed)[0..5]): 8 lowercase characters, 40 bits.
 * Short enough to read over a call, long enough that a collision is not a
 * realistic way to impersonate someone.
 */
export function shortFingerprint(seed: Uint8Array): string {
  if (!(seed instanceof Uint8Array) || seed.length !== 32) {
    throw new TypeError("seed must be 32 bytes");
  }
  const digest = sha256(seed).slice(0, 5);
  let bits = 0;
  let value = 0;
  let out = "";
  for (const byte of digest) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      out += BASE32_ALPHABET[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits > 0) out += BASE32_ALPHABET[(value << (5 - bits)) & 31];
  return out;
}

/**
 * Case- and spacing-tolerant comparison for the confirmation phrase.
 *
 * A phone keyboard will happily give "VANISH", "Vanish" or "Vanish" with a
 * trailing space. All of them mean the same word to the person typing, so all
 * of them pass. Nothing else does.
 */
export function matchesVanishPhrase(text: string): boolean {
  if (typeof text !== "string") return false;
  const folded = text
    .normalize("NFC")
    .replace(/İ/g, "i")
    .replace(/I/g, "i")
    .replace(/ı/g, "i")
    .replace(/\s+/g, " ")
    .trim()
    .toLowerCase();
  return folded === VANISH_PHRASE;
}

async function clipboardCopy(text: string): Promise<void> {
  const clipboard = typeof navigator === "undefined" ? undefined : navigator.clipboard;
  if (clipboard === undefined || typeof clipboard.writeText !== "function") {
    throw new Error("clipboard unavailable");
  }
  await clipboard.writeText(text);
}

function failure(code: ImportCode): ImportResult {
  switch (code) {
    case "empty":
      return { ok: false, code, message: "Paste the backup line first." };
    case "prefix":
      return { ok: false, code, message: `The line does not start with "${EXPORT_PREFIX}".` };
    case "charset":
      return { ok: false, code, message: "The line contains a character outside base32." };
    case "length":
      return {
        ok: false,
        code,
        message: `The line is short or long: it must be ${LINE_LENGTH} characters.`,
      };
    case "checksum":
      return { ok: false, code, message: "The checksum does not match. Copy the whole line." };
    case "unreadable":
      return { ok: false, code, message: "The line could not be read. Paste the backup as it is." };
  }
}

export function createIdentityView(options: IdentityViewOptions = {}): IdentityView {
  const mount = options.mount ?? null;
  const onVanish = options.onVanish;
  const copy = options.copy ?? clipboardCopy;

  let identity: Identity | null = null;
  let line: string | null = null;
  let fingerprint: string | null = null;
  let danger: DangerStep = "idle";
  let vanished = false;

  let dom: IdentityDom | null = null;

  function state(): IdentityViewState {
    return {
      kind: identity === null ? "none" : "ready",
      line,
      fingerprint,
      nextI: identity === null ? null : identity.nextI,
      danger,
      vanished,
    };
  }

  function adopt(next: Identity): void {
    identity = next;
    line = exportIdentity(next.seed, next.nextI, next.generation);
    fingerprint = shortFingerprint(next.seed);
    danger = "idle";
    vanished = false;
    dom?.render();
  }

  function show(seed: Uint8Array, nextI: number, generation = 0): void {
    // `exportIdentity` validates the seed, the index and the generation; bad
    // input throws here rather than producing a line that cannot be imported.
    const next: Identity = { seed: seed.slice(), nextI, generation };
    exportIdentity(next.seed, next.nextI, next.generation);
    adopt(next);
  }

  function importLine(text: string): ImportResult {
    const raw = typeof text === "string" ? text.trim() : "";
    if (raw === "") return fail("empty");

    // Both prefixes, any case: the body is what the checksum protects.
    const folded = raw.toLowerCase();
    const prefix = [EXPORT_PREFIX, LEGACY_EXPORT_PREFIX].find((candidate) =>
      folded.startsWith(candidate),
    );
    if (prefix === undefined) return fail("prefix");
    const body = folded.slice(prefix.length);
    if (!/^[a-z2-7]+$/.test(body)) return fail("charset");
    if (body.length !== BODY_LENGTH) return fail("length");

    let parsed: ImportedIdentity;
    try {
      parsed = importIdentity(raw);
    } catch (error) {
      const message = error instanceof Error ? error.message : "";
      if (message.includes("checksum")) return fail("checksum");
      if (message.includes("length")) return fail("length");
      return fail("unreadable");
    }

    adopt(parsed);
    dom?.setImportStatus(
      parsed.warnings.length > 0
        ? `Identity imported. The line starts with the old "${LEGACY_EXPORT_PREFIX}" prefix; the new one is "${EXPORT_PREFIX}".`
        : "Identity imported.",
    );
    return { ok: true, state: state() };
  }

  function fail(code: ImportCode): ImportResult {
    const result = failure(code);
    if (result.ok === false) dom?.setImportStatus(result.message);
    return result;
  }

  async function copyLine(): Promise<boolean> {
    if (line === null) {
      dom?.setCopyStatus("There is no line to copy.");
      return false;
    }
    try {
      await copy(line);
    } catch {
      dom?.setCopyStatus("Could not copy. Select the line and copy it by hand.");
      return false;
    }
    dom?.setCopyStatus("Line copied.");
    return true;
  }

  function armVanish(): boolean {
    if (identity === null) {
      dom?.setDangerStatus("An identity is required first.");
      return false;
    }
    if (vanished) return false;
    danger = "armed";
    dom?.render();
    return true;
  }

  function cancelVanish(): void {
    if (danger === "confirmed") return;
    danger = "idle";
    dom?.render();
  }

  async function confirmVanish(phrase: string): Promise<VanishOutcome> {
    if (identity === null) return { ok: false, reason: "no-identity" };
    if (vanished) return { ok: false, reason: "done" };
    if (danger !== "armed") return { ok: false, reason: "not-armed" };
    if (!matchesVanishPhrase(phrase)) {
      // The phrase is not echoed back; the instruction is.
      dom?.setDangerStatus(`Type "${VANISH_PHRASE}" to confirm.`);
      return { ok: false, reason: "phrase" };
    }

    danger = "confirmed";
    dom?.render();
    dom?.setDangerStatus("Deletion started. This cannot be undone.");
    try {
      await onVanish?.();
    } catch {
      danger = "armed";
      vanished = false;
      dom?.render();
      dom?.setDangerStatus("Deletion did not finish. Try again.");
      return { ok: false, reason: "failed" };
    }
    vanished = true;
    dom?.render();
    return { ok: true };
  }

  if (mount !== null) {
    dom = buildDom(mount, {
      line: () => line,
      fingerprint: () => fingerprint,
      danger: () => danger,
      vanished: () => vanished,
      copyLine,
      importLine,
      armVanish,
      cancelVanish,
      confirmVanish,
    });
  }

  dom?.render();

  return {
    show,
    importLine,
    copyLine,
    line: () => line,
    fingerprint: () => fingerprint,
    state,
    armVanish,
    confirmVanish,
    cancelVanish,
  };
}

// ---------------------------------------------------------------------------
// DOM
// ---------------------------------------------------------------------------

interface IdentityDomActions {
  line(): string | null;
  fingerprint(): string | null;
  danger(): DangerStep;
  vanished(): boolean;
  copyLine(): Promise<boolean>;
  importLine(text: string): ImportResult;
  armVanish(): boolean;
  cancelVanish(): void;
  confirmVanish(phrase: string): Promise<VanishOutcome>;
}

interface IdentityDom {
  render(): void;
  setCopyStatus(message: string): void;
  setImportStatus(message: string): void;
  setDangerStatus(message: string): void;
}

function buildDom(mount: HTMLElement, actions: IdentityDomActions): IdentityDom {
  const doc = mount.ownerDocument;

  const section = doc.createElement("section");
  section.className = "identity-view";

  const head = doc.createElement("header");
  head.className = "identity-head";
  const title = doc.createElement("h2");
  title.textContent = "Identity";
  head.append(title);

  const lineLabel = doc.createElement("p");
  lineLabel.className = "identity-caption";
  lineLabel.textContent = "Backup line";

  const lineEl = doc.createElement("code");
  lineEl.className = "identity-line";

  const meta = doc.createElement("div");
  meta.className = "identity-meta";

  const fpWrap = doc.createElement("p");
  fpWrap.className = "identity-fp";
  const fpLabel = doc.createElement("span");
  fpLabel.className = "identity-caption";
  fpLabel.textContent = "Fingerprint";
  const fpEl = doc.createElement("code");
  fpEl.className = "identity-fp-value";
  fpWrap.append(fpLabel, fpEl);

  const copyBtn = doc.createElement("button");
  copyBtn.type = "button";
  copyBtn.className = "identity-copy";
  copyBtn.textContent = "Copy";
  copyBtn.addEventListener("click", () => {
    void actions.copyLine();
  });
  meta.append(fpWrap, copyBtn);

  const copyStatus = doc.createElement("p");
  copyStatus.className = "identity-status";
  copyStatus.setAttribute("role", "status");
  copyStatus.setAttribute("aria-live", "polite");

  const warning = doc.createElement("p");
  warning.className = "identity-warning";
  warning.textContent = LOST_WARNING;

  // -- import -------------------------------------------------------------

  const importForm = doc.createElement("form");
  importForm.className = "identity-import";
  importForm.setAttribute("autocomplete", "off");

  const importLabel = doc.createElement("label");
  importLabel.className = "identity-caption";
  importLabel.append("Import");

  const importInput = doc.createElement("input");
  importInput.type = "text";
  importInput.className = "identity-import-input";
  importInput.setAttribute("spellcheck", "false");
  importInput.setAttribute("autocapitalize", "off");
  importInput.setAttribute("autocorrect", "off");

  const importBtn = doc.createElement("button");
  importBtn.type = "submit";
  importBtn.className = "identity-import-button";
  importBtn.textContent = "Import";

  const importStatus = doc.createElement("p");
  importStatus.className = "identity-import-status";
  importStatus.setAttribute("role", "status");
  importStatus.setAttribute("aria-live", "polite");

  importForm.append(importLabel, importInput, importBtn, importStatus);
  importForm.addEventListener("submit", (event: Event) => {
    event.preventDefault();
    const result = actions.importLine(importInput.value);
    // A good line is cleared at once: a seed should not sit in a form field.
    if (result.ok) importInput.value = "";
  });

  // -- danger zone --------------------------------------------------------

  const dangerZone = doc.createElement("section");
  dangerZone.className = "identity-danger";
  dangerZone.setAttribute("aria-label", "Danger zone");

  const dangerTitle = doc.createElement("h3");
  dangerTitle.className = "identity-danger-title";
  dangerTitle.textContent = "Danger zone";

  const dangerBody = doc.createElement("p");
  dangerBody.className = "identity-danger-body";
  dangerBody.textContent =
    "Deletes all your posts and listings. Irreversible.";

  const armBtn = doc.createElement("button");
  armBtn.type = "button";
  armBtn.className = "identity-arm";
  armBtn.textContent = "Vanish";
  armBtn.addEventListener("click", () => {
    actions.armVanish();
  });

  const confirmBox = doc.createElement("div");
  confirmBox.className = "identity-confirm";

  const confirmLabel = doc.createElement("label");
  confirmLabel.className = "identity-confirm-label";
  confirmLabel.append(`Type "${VANISH_PHRASE}" to confirm`);

  const confirmInput = doc.createElement("input");
  confirmInput.type = "text";
  confirmInput.className = "identity-confirm-input";
  confirmInput.setAttribute("autocomplete", "off");
  confirmInput.setAttribute("spellcheck", "false");
  confirmInput.setAttribute("autocapitalize", "off");
  confirmLabel.append(confirmInput);

  const confirmRow = doc.createElement("div");
  confirmRow.className = "identity-confirm-row";

  const confirmBtn = doc.createElement("button");
  confirmBtn.type = "button";
  confirmBtn.className = "identity-confirm-button";
  confirmBtn.textContent = "Delete permanently";
  confirmBtn.addEventListener("click", () => {
    void actions.confirmVanish(confirmInput.value);
  });

  const cancelBtn = doc.createElement("button");
  cancelBtn.type = "button";
  cancelBtn.className = "identity-cancel";
  cancelBtn.textContent = "Cancel";
  cancelBtn.addEventListener("click", () => {
    actions.cancelVanish();
  });

  confirmRow.append(confirmBtn, cancelBtn);

  const dangerStatus = doc.createElement("p");
  dangerStatus.className = "identity-danger-status";
  dangerStatus.setAttribute("role", "status");
  dangerStatus.setAttribute("aria-live", "polite");

  confirmBox.append(confirmLabel, confirmRow, dangerStatus);
  dangerZone.append(dangerTitle, dangerBody, armBtn, confirmBox);

  section.append(head, lineLabel, lineEl, meta, copyStatus, warning, importForm, dangerZone);
  mount.replaceChildren(section);

  function render(): void {
    const current = actions.line();
    lineEl.textContent = current ?? "—";
    lineEl.dataset.empty = current === null ? "1" : "0";
    fpEl.textContent = actions.fingerprint() ?? "--------";

    const ready = current !== null;
    copyBtn.disabled = !ready;
    armBtn.disabled = !ready || actions.vanished();

    const step = actions.danger();
    confirmBox.hidden = step === "idle";
    armBtn.hidden = step !== "idle";
    confirmBtn.disabled = step !== "armed";
    confirmInput.disabled = step !== "armed";
    dangerZone.dataset.step = step;

    if (step === "idle") {
      confirmInput.value = "";
      dangerStatus.textContent = "";
    }
  }

  function setStatus(el: HTMLElement, message: string): void {
    el.textContent = message;
  }

  return {
    render,
    setCopyStatus: (message) => setStatus(copyStatus, message),
    setImportStatus: (message) => setStatus(importStatus, message),
    setDangerStatus: (message) => setStatus(dangerStatus, message),
  };
}
