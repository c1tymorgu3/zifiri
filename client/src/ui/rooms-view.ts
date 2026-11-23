/**
 * Odalar — the room list, the message stream, and the composer.
 *
 * Three things this surface refuses to draw, each for a reason the product
 * states elsewhere:
 *
 *  - No avatar and no name beside a message. A room has no accounts; a name
 *    would be a label the server does not have and the reader cannot verify.
 *  - No presence marker unless presence is on. "Offline" is still a trace;
 *    when the toggle is off the row says nothing at all.
 *  - No "gönderildi" tick. In silent mode the message waits for the bucket, so
 *    the honest indicator is the queue ("2 bekliyor"), not a delivery claim.
 *
 * The clock beside a message is the message's own published time — the bucket
 * boundary it was released with — never the moment the writer pressed send.
 * That distinction is the product's whole timing claim, so the label is drawn
 * from `at` and nothing else.
 *
 * Built with `createElement` and `textContent` throughout: no `innerHTML`, no
 * storage, no network. The caller owns the data and the send.
 */

import "../styles/rooms.css";
import { anonymityCount, DEFAULT_MODE, describeMode, isMode, type Mode } from "./mode";

/** Characters, not bytes: a Turkish letter is one character to the writer. */
export const CHAR_LIMIT = 500;

/** The sentence the silent mode is sold with; kept in one place so the copy cannot drift. */
export const SILENT_WAIT = "10 dakikaya kadar bekler";

export const EMPTY_ROOMS = "Henüz oda yok; ilk oda açıldığında burada listelenir.";

export const EMPTY_MESSAGES = "Bu odada henüz mesaj yok; ilk mesaj 10 dakikalık kovaya girer.";

export const NO_ROOM = "Bir oda seç; mesajlar o odada görünür.";

export interface RoomSummary {
  readonly id: string;
  readonly name: string;
  /** Epoch ms of the newest published message. */
  readonly lastActivityAt: number;
  readonly unread: number;
  /**
   * True only when presence is enabled *and* someone is present. When the
   * toggle is off, pass `false`: the row then draws nothing, because an
   * "offline" marker is itself a trace.
   */
  readonly presence: boolean;
}

export interface RoomMessage {
  readonly id: string;
  readonly body: string;
  /** Epoch ms the message was published with its bucket. */
  readonly at: number;
}

export interface RoomListOptions {
  readonly now: number;
  readonly activeId: string | null;
  readonly onSelect?: (roomId: string) => void;
}

/** Newest activity first; ties fall back to the name so the order never jitters. */
export function sortRooms(rooms: readonly RoomSummary[]): RoomSummary[] {
  return [...rooms].sort((a, b) => {
    if (b.lastActivityAt !== a.lastActivityAt) return b.lastActivityAt - a.lastActivityAt;
    return a.name.localeCompare(b.name, "tr");
  });
}

const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

/** Compact age for a list row: `şimdi`, `3 dk`, `2 sa`, `4 g`. */
export function relativeTime(at: number, now: number): string {
  const age = Math.max(0, now - at);
  if (age < MINUTE) return "şimdi";
  if (age < HOUR) return `${Math.floor(age / MINUTE)} dk`;
  if (age < DAY) return `${Math.floor(age / HOUR)} sa`;
  return `${Math.floor(age / DAY)} g`;
}

/** The same age as a sentence fragment: `şimdi` or `3 dk önce`. */
export function sinceLabel(at: number, now: number): string {
  const short = relativeTime(at, now);
  return short === "şimdi" ? short : `${short} önce`;
}

function pad2(value: number): string {
  return value < 10 ? `0${value}` : String(value);
}

/** 24-hour local clock, zero-padded; the only place a time is formatted. */
export function clockLabel(at: number): string {
  const date = new Date(at);
  return `${pad2(date.getHours())}:${pad2(date.getMinutes())}`;
}

/** Code points, so an emoji costs one character and not two. */
export function countChars(text: string): number {
  return [...text].length;
}

export function isOverLimit(text: string): boolean {
  return countChars(text) > CHAR_LIMIT;
}

function element<K extends keyof HTMLElementTagNameMap>(
  doc: Document,
  tag: K,
  className: string,
): HTMLElementTagNameMap[K] {
  const node = doc.createElement(tag);
  node.className = className;
  return node;
}

function visuallyHidden(doc: Document, text: string): HTMLSpanElement {
  const node = element(doc, "span", "zf-visually-hidden");
  node.textContent = text;
  return node;
}

function requireDocument(root: HTMLElement): Document {
  const doc = root.ownerDocument ?? (typeof document === "undefined" ? null : document);
  if (doc === null) throw new Error("rooms-view bir belge gerektirir");
  return doc;
}

/**
 * Draws the room list into `root`. Empty list gets one sentence, no picture.
 * The active room is marked with `aria-current` and the amber rule is CSS.
 */
export function renderRoomList(
  root: HTMLElement,
  rooms: readonly RoomSummary[],
  options: RoomListOptions,
): void {
  const doc = requireDocument(root);
  const sorted = sortRooms(rooms);

  root.replaceChildren();

  if (sorted.length === 0) {
    const empty = element(doc, "p", "zf-empty");
    empty.textContent = EMPTY_ROOMS;
    root.append(empty);
    return;
  }

  const list = element(doc, "ul", "zf-rooms-list");

  for (const room of sorted) {
    const slot = element(doc, "li", "zf-room-slot");
    const row = element(doc, "button", "zf-room");
    row.type = "button";
    row.setAttribute("data-room-id", room.id);
    if (room.id === options.activeId) row.setAttribute("aria-current", "true");

    const name = element(doc, "span", "zf-room-name");
    name.textContent = room.name;

    const meta = element(doc, "span", "zf-room-meta");

    const time = element(doc, "time", "zf-room-time");
    time.setAttribute("datetime", new Date(room.lastActivityAt).toISOString());
    time.textContent = relativeTime(room.lastActivityAt, options.now);
    meta.append(time);

    if (room.unread > 0) {
      const unread = element(doc, "span", "zf-room-unread");
      const count = element(doc, "span", "zf-room-unread-count");
      count.textContent = String(room.unread);
      unread.append(visuallyHidden(doc, "okunmamış "), count);
      meta.append(unread);
    }

    row.append(name, meta);

    if (room.presence) {
      const dot = element(doc, "span", "zf-room-dot");
      dot.setAttribute("role", "img");
      dot.setAttribute("aria-label", "şu an açık");
      row.append(dot);
    }

    if (options.onSelect !== undefined) {
      const onSelect = options.onSelect;
      row.addEventListener("click", () => onSelect(room.id));
    }

    slot.append(row);
    list.append(slot);
  }

  root.append(list);
}

export interface StreamOptions {
  /** Shown when there is nothing to draw; defaults to {@link EMPTY_MESSAGES}. */
  readonly empty?: string;
}

/** Message rows: text, mono clock. No avatar, no name, no status tick. */
export function renderMessageStream(
  root: HTMLElement,
  messages: readonly RoomMessage[],
  options: StreamOptions = {},
): void {
  const doc = requireDocument(root);
  root.replaceChildren();

  if (messages.length === 0) {
    const empty = element(doc, "p", "zf-empty");
    empty.textContent = options.empty ?? EMPTY_MESSAGES;
    root.append(empty);
    return;
  }

  const list = element(doc, "ol", "zf-stream-list");

  for (const message of messages) {
    const row = element(doc, "li", "zf-msg");

    const body = element(doc, "span", "zf-msg-body");
    body.textContent = message.body;

    const clock = element(doc, "time", "zf-msg-clock");
    clock.setAttribute("datetime", new Date(message.at).toISOString());
    clock.textContent = clockLabel(message.at);

    row.append(body, clock);
    list.append(row);
  }

  root.append(list);
  root.scrollTop = root.scrollHeight;
}

export interface RoomsViewOptions {
  /** The view renders inside this element. */
  readonly mount: HTMLElement;
  readonly now?: () => number;
  readonly onSend?: (message: { roomId: string; body: string; mode: Mode }) => void;
  readonly onSelectRoom?: (roomId: string) => void;
  readonly activeRoomId?: string | null;
  readonly mode?: Mode;
  readonly rooms?: readonly RoomSummary[];
  readonly messages?: readonly RoomMessage[];
  readonly pending?: number;
  /** Messages published in the last minute; the fast-mode neighbourhood. */
  readonly anonymity?: number;
  /** Called when the writer cancels a proof-of-work grind. */
  readonly onCancel?: () => void;
}

export interface RoomsView {
  readonly root: HTMLElement;
  readonly form: HTMLFormElement;
  readonly input: HTMLTextAreaElement;
  setRooms(rooms: readonly RoomSummary[]): void;
  setMessages(messages: readonly RoomMessage[]): void;
  setRoom(roomId: string | null): void;
  setMode(mode: Mode): void;
  setPending(count: number): void;
  /** The live neighbourhood size; fast mode shows the last-minute count. */
  setAnonymity(count: number): void;
  /** Proof-of-work progress: attempts so far, or null when idle. */
  setPow(attempts: number | null): void;
  /** Locks the send button while a message is in flight. */
  setSending(sending: boolean): void;
  mode(): Mode;
  value(): string;
  setValue(text: string): void;
  /** Submits the composer the way the send button does; no-op when blocked. */
  send(): void;
  destroy(): void;
}

let viewCount = 0;

export function createRoomsView(options: RoomsViewOptions): RoomsView {
  const mount = options.mount;
  const doc = requireDocument(mount);
  const now = options.now ?? (() => Date.now());

  viewCount += 1;
  const uid = viewCount;

  let rooms: readonly RoomSummary[] = options.rooms ?? [];
  let messages: readonly RoomMessage[] = options.messages ?? [];
  let activeRoomId: string | null = options.activeRoomId ?? null;
  let mode: Mode = options.mode ?? DEFAULT_MODE;
  let pending = options.pending ?? 0;
  let recent = options.anonymity ?? 1;
  let sending = false;

  const section = element(doc, "section", "zf-rooms");
  section.setAttribute("aria-label", "Odalar");

  const index = element(doc, "div", "zf-rooms-index");
  const indexTitle = element(doc, "h2", "zf-panel-title");
  indexTitle.textContent = "Odalar";
  const listRoot = element(doc, "div", "zf-rooms-index-body");
  index.append(indexTitle, listRoot);

  const room = element(doc, "div", "zf-room-pane");

  const head = element(doc, "header", "zf-room-head");
  const title = element(doc, "h2", "zf-room-title");
  const sub = element(doc, "p", "zf-room-sub");
  head.append(title, sub);

  const stream = element(doc, "div", "zf-stream");
  stream.setAttribute("role", "log");
  stream.setAttribute("aria-live", "polite");
  stream.setAttribute("aria-label", "Mesajlar");

  const form = element(doc, "form", "zf-composer");
  form.setAttribute("novalidate", "");

  const inputId = `zf-input-${uid}`;
  const counterId = `zf-counter-${uid}`;
  const consequenceId = `zf-consequence-${uid}`;

  const label = element(doc, "label", "zf-visually-hidden");
  label.setAttribute("for", inputId);
  label.textContent = "Mesaj";

  const input = element(doc, "textarea", "zf-composer-input");
  input.id = inputId;
  input.rows = 3;
  input.setAttribute("placeholder", "Odaya yaz");
  input.setAttribute("aria-describedby", `${consequenceId} ${counterId}`);

  const bar = element(doc, "div", "zf-composer-bar");

  const modes = element(doc, "div", "zf-modes");
  modes.setAttribute("role", "radiogroup");
  modes.setAttribute("aria-label", "Gönderim modu");

  const radioName = `zf-mode-${uid}`;
  const radios = new Map<Mode, HTMLInputElement>();

  for (const value of ["fast", "silent"] as const) {
    const option = element(doc, "label", "zf-mode");
    const radio = element(doc, "input", "zf-mode-input");
    radio.type = "radio";
    radio.name = radioName;
    radio.value = value;
    radio.addEventListener("change", () => {
      if (radio.checked) setMode(value);
    });
    const caption = element(doc, "span", "zf-mode-label");
    caption.textContent = value === "fast" ? "Hızlı" : "Sessiz";
    option.append(radio, caption);
    radios.set(value, radio);
    modes.append(option);
  }

  const anonymity = element(doc, "span", "zf-anonymity");
  anonymity.setAttribute("role", "status");
  anonymity.setAttribute("aria-live", "polite");

  const counter = element(doc, "span", "zf-counter");
  counter.id = counterId;

  const send = element(doc, "button", "zf-send");
  send.type = "submit";
  send.textContent = "Gönder";

  bar.append(modes, anonymity, counter, send);

  const consequence = element(doc, "p", "zf-consequence");
  consequence.id = consequenceId;

  const pendingLine = element(doc, "p", "zf-pending");
  pendingLine.setAttribute("data-role", "pending");

  const pow = element(doc, "div", "zf-pow");
  pow.setAttribute("data-role", "pow");
  pow.setAttribute("hidden", "");

  const powBar = element(doc, "progress", "zf-pow-bar");
  powBar.setAttribute("max", "100");

  const powLabel = element(doc, "span", "zf-pow-label");
  powLabel.setAttribute("role", "status");
  powLabel.setAttribute("aria-live", "polite");

  const powCancel = element(doc, "button", "zf-pow-cancel");
  powCancel.type = "button";
  powCancel.textContent = "iptal";
  powCancel.addEventListener("click", () => options.onCancel?.());

  pow.append(powBar, powLabel, powCancel);

  form.append(label, input, bar, consequence, pendingLine, pow);

  room.append(head, stream, form);
  section.append(index, room);
  mount.replaceChildren(section);

  function canSend(): boolean {
    return (
      !sending &&
      activeRoomId !== null &&
      input.value.trim() !== "" &&
      !isOverLimit(input.value)
    );
  }

  function paintAnonymity(): void {
    anonymity.textContent = `anonimlik: ${anonymityCount(mode, recent)}`;
  }

  function paintCounter(): void {
    const chars = countChars(input.value);
    counter.textContent =
      chars > CHAR_LIMIT ? `${chars} / ${CHAR_LIMIT} · ${chars - CHAR_LIMIT} fazla` : `${chars} / ${CHAR_LIMIT}`;
    counter.setAttribute("data-state", chars > CHAR_LIMIT ? "over" : "ok");
    if (canSend()) send.removeAttribute("disabled");
    else send.setAttribute("disabled", "");
  }

  function paintPending(): void {
    // Silent mode always says what the queue is doing — including "nothing" —
    // because the wait is the cost of the mode the writer just picked. Fast
    // mode has no queue, so the line is not drawn at all.
    if (mode !== "silent") {
      pendingLine.setAttribute("hidden", "");
      pendingLine.textContent = "";
      return;
    }
    pendingLine.removeAttribute("hidden");
    pendingLine.textContent =
      pending <= 0 ? `${SILENT_WAIT} · bekleyen yok` : `${SILENT_WAIT} · ${pending} bekliyor`;
  }

  function paintRoomHead(): void {
    const current = rooms.find((candidate) => candidate.id === activeRoomId);
    if (current === undefined) {
      title.textContent = "Oda seçilmedi";
      sub.textContent = "";
      sub.setAttribute("hidden", "");
      form.setAttribute("hidden", "");
      renderMessageStream(stream, [], { empty: NO_ROOM });
      return;
    }
    title.textContent = current.name;
    sub.textContent = `son mesaj ${sinceLabel(current.lastActivityAt, now())}`;
    sub.removeAttribute("hidden");
    form.removeAttribute("hidden");
    renderMessageStream(stream, messages);
  }

  function paintRooms(): void {
    renderRoomList(listRoot, rooms, {
      now: now(),
      activeId: activeRoomId,
      ...(options.onSelectRoom === undefined
        ? {}
        : { onSelect: (roomId: string) => options.onSelectRoom?.(roomId) }),
    });
  }

  function setMode(next: Mode): void {
    mode = next;
    for (const [value, radio] of radios) {
      radio.checked = value === next;
    }
    form.setAttribute("data-mode", next);
    consequence.textContent = describeMode(next);
    paintAnonymity();
    paintPending();
  }

  function deliver(): void {
    if (!canSend() || activeRoomId === null) return;
    const body = input.value.trim();
    options.onSend?.({ roomId: activeRoomId, body, mode });
    input.value = "";
    paintCounter();
  }

  input.addEventListener("input", paintCounter);

  form.addEventListener("submit", (event) => {
    event.preventDefault();
    deliver();
    input.focus();
  });

  setMode(mode);
  paintCounter();
  paintAnonymity();
  paintPending();
  paintRoomHead();
  paintRooms();

  return {
    root: section,
    form,
    input,
    setRooms(next: readonly RoomSummary[]): void {
      rooms = next;
      paintRooms();
      paintRoomHead();
    },
    setMessages(next: readonly RoomMessage[]): void {
      messages = next;
      paintRoomHead();
    },
    setRoom(roomId: string | null): void {
      activeRoomId = roomId;
      paintRooms();
      paintRoomHead();
      paintCounter();
    },
    setMode,
    setPending(count: number): void {
      pending = Math.max(0, Math.trunc(count));
      paintPending();
    },
    setAnonymity(count: number): void {
      recent = Math.max(1, Math.trunc(count));
      paintAnonymity();
    },
    setPow(attempts: number | null): void {
      if (attempts === null) {
        pow.setAttribute("hidden", "");
        powLabel.textContent = "";
        powBar.removeAttribute("value");
        return;
      }
      pow.removeAttribute("hidden");
      // Indeterminate: the number of attempts is real, the total is not.
      powBar.removeAttribute("value");
      powLabel.textContent = `deneme ${attempts}`;
    },
    setSending(next: boolean): void {
      sending = next;
      form.setAttribute("aria-busy", next ? "true" : "false");
      send.textContent = next ? "Gönderiliyor" : "Gönder";
      paintCounter();
    },
    mode: () => mode,
    value: () => input.value,
    setValue(text: string): void {
      input.value = text;
      paintCounter();
    },
    send(): void {
      deliver();
    },
    destroy(): void {
      section.remove();
    },
  };
}
