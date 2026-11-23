/**
 * Messages (1:1) surface: conversation list, thread, composer, presence.
 *
 * Three rules from `docs/spec.md` shape everything below.
 *
 *  1. Rules, not boxes. A thread is a list of rows separated by a hairline:
 *     mono clock, text, nothing else. No bubbles, no avatars, no names —
 *     the protocol has no name to show, and a bubble would imply a chat app
 *     this is not. Own messages are set apart by an 8px indent, never by
 *     colour.
 *  2. Presence is off until the user turns it on, and off means *silent*.
 *     The label falls back to "bilinmiyor" before the probe function is
 *     touched, and switching it off drops every cached label so no dot can
 *     survive on a row (scope v5, presence_test).
 *  3. The composer carries the same mode switch as Odalar: Hızlı by default
 *     (scope v5), Sessiz on request, remembered in memory only. The one-line
 *     consequence sits under it, because a mode that changes how hidden a
 *     message is must say so before it is used.
 *
 * Text in, text out: every node is built with `createElement` and
 * `textContent`; a peer's message is never parsed as markup.
 *
 * The module is a thin state machine over `DmThread[]`; sealing and delivery
 * stay in `ui/dm.ts` and reach the wire only through `onSend`.
 */
import {
  peerLabel,
  presenceState,
  summarize,
  unreadCount,
  type DmMessage,
  type DmThread,
  type PresenceFn,
  type PresenceLabel,
} from "./dm";
import { DEFAULT_MODE, describeMode, type Mode } from "./mode";

/** Composer cap: one message must fit one 4 KB bucket with its envelope. */
export const MAX_BODY = 2000;

/**
 * Bucket mode, in the words the switch shows: Hızlı / Sessiz. Odalar speaks the
 * same two modes under the same labels; the ids differ because this surface
 * asks once before switching to fast, and that question is written in Turkish.
 */
export type DmMode = "hizli" | "sessiz";

/** The one-line consequence each mode owes the user before it is used. */
export const MODE_NOTE: Record<DmMode, string> = {
  hizli: "yazma anın ~%80 gizli · mesaj hemen gider",
  sessiz: "yazma anın ~%99 gizli · 10 dakikalık kovada bekler",
};

/** The sentence the ask-once row carries before the first fast send. */
export const FAST_ASK = "Hızlı mod yazma anını ~%80 gizli bırakır. Sessiz mod ~%99.";

export interface DmViewOptions {
  /** Panel renders inside this element. Omit it for the DOM-free core. */
  mount?: HTMLElement | null;
  /** Hands a non-empty draft to the transport. Rejections are shown, not thrown. */
  onSend: (peer: string, text: string, mode: DmMode) => void | Promise<void>;
  /** Fires when the user opens a conversation, so the caller can mark it read. */
  onOpen?: (peer: string) => void;
  /** Presence probe. Absent means presence is unavailable, not "off". */
  presence?: PresenceFn;
  now?: () => number;
  /** Presence starts off unless the user has already opted in this session. */
  presenceEnabled?: boolean;
  /** Bucket mode starts fast unless the session already chose. */
  mode?: DmMode;
}

export interface DmViewState {
  readonly presenceEnabled: boolean;
  readonly presence: PresenceLabel;
  readonly selected: string | null;
  readonly draft: string;
  readonly unread: number;
  readonly threadCount: number;
  readonly mode: DmMode;
  /** True while the ask-once row is waiting for an answer. */
  readonly askMode: boolean;
  readonly loading: boolean;
}

export interface DmView {
  /** Replaces the conversation list; selection survives if its peer does. */
  setThreads(threads: readonly DmThread[]): void;
  /** Opens a conversation and probes presence if (and only if) it is on. */
  select(peer: string | null): Promise<PresenceLabel>;
  /** Turns presence on or off. Off never calls the probe and clears labels. */
  setPresenceEnabled(enabled: boolean): Promise<PresenceLabel>;
  /** Re-probes the open conversation. A no-op with presence off. */
  refreshPresence(): Promise<PresenceLabel>;
  /** Skeleton rows while the first pull is in flight. */
  setLoading(loading: boolean): void;
  /**
   * Switches the bucket mode. The first switch to Hızlı only asks; the mode
   * changes when `confirmFastMode` runs, so a privacy downgrade is never a
   * stray click.
   */
  setMode(mode: DmMode): void;
  /** Answers the ask row: yes, use Hızlı from here on. */
  confirmFastMode(): void;
  /** Answers the ask row: no, stay where we were. */
  cancelFastMode(): void;
  setDraft(text: string): void;
  /** Sends the draft. False when empty, unselected or rejected by `onSend`. */
  submit(): Promise<boolean>;
  state(): DmViewState;
  /** Drops every conversation from memory (identity cleared, "yok ol"). */
  clear(): void;
}

/** `HH:MM` in the device's zone. Invalid or zero timestamps read as `--:--`. */
export function clockLabel(at: number): string {
  if (!Number.isFinite(at) || at <= 0) return "--:--";
  const date = new Date(at);
  const hours = String(date.getHours()).padStart(2, "0");
  const minutes = String(date.getMinutes()).padStart(2, "0");
  return `${hours}:${minutes}`;
}

/** Coarse relative time for the list: "şimdi", "3 dk", "2 sa", "4 g". */
export function relativeLabel(at: number, now: number): string {
  if (!Number.isFinite(at) || at <= 0) return "";
  const minutes = Math.floor(Math.max(0, now - at) / 60_000);
  if (minutes < 1) return "şimdi";
  if (minutes < 60) return `${minutes} dk`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours} sa`;
  return `${Math.floor(hours / 24)} g`;
}

export function createDmView(options: DmViewOptions): DmView {
  const now = options.now ?? Date.now;
  const probe = options.presence;
  const onSend = options.onSend;
  const onOpen = options.onOpen;
  const mount = options.mount ?? null;

  let threads: DmThread[] = [];
  let selected: string | null = null;
  let enabled = options.presenceEnabled === true;
  let draft = "";
  let labels = new Map<string, PresenceLabel>();
  // Silent unless the session already chose; the ask-once gate guards Hızlı.
  let mode: DmMode = options.mode ?? (DEFAULT_MODE === "fast" ? "hizli" : "sessiz");
  let askMode = false;
  let askedFast = false;
  let loading = false;
  let dom: DmDom | null = null;

  function threadFor(peer: string | null): DmThread | undefined {
    if (peer === null) return undefined;
    return threads.find((thread) => thread.peer === peer);
  }

  function presenceOf(peer: string): PresenceLabel {
    if (!enabled) return "bilinmiyor";
    return labels.get(peer) ?? "bilinmiyor";
  }

  function state(): DmViewState {
    return {
      presenceEnabled: enabled,
      presence: selected === null ? "bilinmiyor" : presenceOf(selected),
      selected,
      draft,
      unread: unreadCount(threads),
      threadCount: threads.length,
      mode,
      askMode,
      loading,
    };
  }

  function render(): void {
    dom?.render();
  }

  function setThreads(next: readonly DmThread[]): void {
    threads = Array.isArray(next) ? next.slice() : [];
    const alive = new Set(threads.map((thread) => thread.peer));
    for (const peer of [...labels.keys()]) {
      if (!alive.has(peer)) labels.delete(peer);
    }
    if (selected !== null && !alive.has(selected)) {
      selected = null;
      draft = "";
    }
    render();
  }

  function setLoading(next: boolean): void {
    loading = next === true;
    render();
  }

  async function refreshPresence(): Promise<PresenceLabel> {
    const thread = threadFor(selected);
    if (!enabled || thread === undefined || thread.peerKey === null) {
      render();
      return "bilinmiyor";
    }
    // `presenceState` returns before the probe when the switch is off; the
    // `enabled` check above is the second lock on the same door.
    const label = await presenceState(thread.peerKey, enabled, probe, now);
    if (enabled && selected === thread.peer) labels.set(thread.peer, label);
    render();
    return label;
  }

  async function select(peer: string | null): Promise<PresenceLabel> {
    if (peer !== selected) {
      selected = peer;
      draft = "";
    }
    if (peer !== null) onOpen?.(peer);
    render();
    if (peer === null) return "bilinmiyor";
    return refreshPresence();
  }

  async function setPresenceEnabled(next: boolean): Promise<PresenceLabel> {
    enabled = next === true;
    if (!enabled) {
      labels = new Map();
      render();
      return "bilinmiyor";
    }
    return refreshPresence();
  }

  function setMode(next: DmMode): void {
    if (next === "hizli" && !askedFast) {
      askMode = true;
      render();
      return;
    }
    askMode = false;
    mode = next;
    render();
  }

  function confirmFastMode(): void {
    askedFast = true;
    askMode = false;
    mode = "hizli";
    render();
  }

  function cancelFastMode(): void {
    askMode = false;
    render();
  }

  function setDraft(text: string): void {
    draft = typeof text === "string" ? text.slice(0, MAX_BODY) : "";
    dom?.setStatus("");
    dom?.renderComposer();
  }

  async function submit(): Promise<boolean> {
    const peer = selected;
    const text = draft.trim();
    if (peer === null || text === "") return false;
    try {
      await onSend(peer, text, mode);
    } catch {
      // Keep the draft: a failed send must not cost the user their words.
      dom?.setStatus("Gönderilemedi. Bağlantıyı kontrol et.");
      return false;
    }
    draft = "";
    dom?.renderComposer();
    dom?.setStatus("Gönderildi.");
    return true;
  }

  function clear(): void {
    threads = [];
    selected = null;
    draft = "";
    labels = new Map();
    render();
  }

  if (mount !== null) {
    dom = buildDom(mount, {
      select,
      submit,
      setDraft,
      setPresenceEnabled,
      setMode,
      confirmFastMode,
      cancelFastMode,
      askModeOn: () => askMode,
      presenceOn: () => enabled,
      threadList: () => threads,
      selectedPeer: () => selected,
      draftText: () => draft,
      presenceOf,
      modeOf: () => mode,
      isLoading: () => loading,
      now,
    });
  }

  render();

  return {
    setThreads,
    select,
    setPresenceEnabled,
    refreshPresence,
    setLoading,
    setMode,
    confirmFastMode,
    cancelFastMode,
    setDraft,
    submit,
    state,
    clear,
  };
}

// ---------------------------------------------------------------------------
// DOM
// ---------------------------------------------------------------------------

interface DmDomActions {
  select(peer: string): Promise<PresenceLabel>;
  submit(): Promise<boolean>;
  setDraft(text: string): void;
  setPresenceEnabled(enabled: boolean): Promise<PresenceLabel>;
  setMode(mode: DmMode): void;
  confirmFastMode(): void;
  cancelFastMode(): void;
  askModeOn(): boolean;
  presenceOn(): boolean;
  threadList(): readonly DmThread[];
  selectedPeer(): string | null;
  draftText(): string;
  presenceOf(peer: string): PresenceLabel;
  modeOf(): DmMode;
  isLoading(): boolean;
  now(): number;
}

interface DmDom {
  render(): void;
  renderComposer(): void;
  setStatus(message: string): void;
}

/**
 * Builds the panel once and rebuilds only the two columns. `textContent` for
 * every string, `dataset` for peer ids: a peer key is data, not markup.
 */
function buildDom(mount: HTMLElement, actions: DmDomActions): DmDom {
  const doc = mount.ownerDocument;

  const section = doc.createElement("section");
  section.className = "dm";

  const head = doc.createElement("header");
  head.className = "dm-head";

  const title = doc.createElement("h2");
  title.textContent = "Konuşmalar";

  const toggleLabel = doc.createElement("label");
  toggleLabel.className = "dm-toggle";
  const toggle = doc.createElement("input");
  toggle.type = "checkbox";
  toggle.checked = actions.presenceOn();
  toggle.addEventListener("change", () => {
    void actions.setPresenceEnabled(toggle.checked);
  });
  toggleLabel.append(toggle, "Durum bilgisi");

  head.append(title, toggleLabel);

  const presenceNote = doc.createElement("p");
  presenceNote.className = "dm-note";
  presenceNote.textContent =
    "Kapalıyken kimse çevrimiçi olduğunu görmez; bu cihaz da kimseyi yoklamaz.";

  const body = doc.createElement("div");
  body.className = "dm-body";

  const list = doc.createElement("ul");
  list.className = "dm-list";
  list.setAttribute("aria-label", "Konuşmalar");

  const thread = doc.createElement("section");
  thread.className = "dm-thread";
  thread.setAttribute("aria-label", "Konuşma");

  body.append(list, thread);
  section.append(head, presenceNote, body);
  mount.replaceChildren(section);

  let composer: {
    input: HTMLTextAreaElement;
    counter: HTMLElement;
    send: HTMLButtonElement;
  } | null = null;

  let status: HTMLElement | null = null;

  function renderSkeletons(): void {
    // Static hairline placeholders; no spinner, no pulse (DESIGN, States).
    const rows: HTMLElement[] = [];
    for (let index = 0; index < 3; index += 1) {
      const cell = doc.createElement("li");
      cell.className = "dm-skeleton";
      cell.setAttribute("aria-hidden", "true");
      const bar = doc.createElement("span");
      bar.className = "dm-skeleton-bar";
      cell.append(bar);
      rows.push(cell);
    }
    const note = doc.createElement("p");
    note.className = "dm-visually-hidden";
    note.textContent = "Konuşmalar yükleniyor.";
    list.replaceChildren(...rows, note);
  }

  function renderList(): void {
    const threads = actions.threadList();
    if (threads.length === 0) {
      if (actions.isLoading()) {
        renderSkeletons();
        return;
      }
      const cell = doc.createElement("li");
      const empty = doc.createElement("p");
      empty.className = "dm-empty";
      empty.textContent = "Henüz kimseyle konuşmadın.";
      cell.append(empty);
      list.replaceChildren(cell);
      return;
    }

    const current = actions.selectedPeer();
    const stamp = actions.now();
    const rows: HTMLElement[] = [];

    for (const item of threads) {
      const cell = doc.createElement("li");
      const button = doc.createElement("button");
      button.type = "button";
      button.className = "dm-row";
      button.dataset.peer = item.peer;
      if (item.peer === current) button.setAttribute("aria-current", "true");

      const peer = doc.createElement("span");
      peer.className = "dm-fp";
      peer.textContent = peerLabel(item);

      const preview = doc.createElement("span");
      preview.className = "dm-preview";
      preview.textContent = item.lastText === "" ? "mesaj yok" : summarize(item.lastText);

      const when = doc.createElement("time");
      when.className = "dm-when";
      when.textContent = relativeLabel(item.lastAt, stamp);

      const meta = doc.createElement("span");
      meta.className = "dm-meta";
      meta.append(when);

      const label = actions.presenceOf(item.peer);
      if (actions.presenceOn() && label !== "bilinmiyor") {
        const dot = doc.createElement("span");
        dot.className = `dm-dot ${label === "çevrimiçi" ? "dm-dot--ok" : "dm-dot--idle"}`;
        dot.setAttribute("aria-hidden", "true");
        meta.append(dot);
      }

      if (item.unread > 0) {
        const badge = doc.createElement("span");
        badge.className = "dm-unread";
        badge.setAttribute("aria-label", `${item.unread} okunmamış`);
        badge.textContent = String(item.unread);
        meta.append(badge);
      }

      button.append(peer, preview, meta);
      button.addEventListener("click", () => {
        void actions.select(item.peer);
      });
      cell.append(button);
      rows.push(cell);
    }

    list.replaceChildren(...rows);
  }

  function renderThread(): void {
    const peer = actions.selectedPeer();
    const item = peer === null ? undefined : actions.threadList().find((t) => t.peer === peer);
    composer = null;
    status = null;

    if (item === undefined) {
      const hint = doc.createElement("p");
      hint.className = "dm-pick";
      hint.textContent = "Konuşmak için soldan bir satır seç.";
      thread.replaceChildren(hint);
      return;
    }

    const threadHead = doc.createElement("header");
    threadHead.className = "dm-thread-head";

    const name = doc.createElement("h3");
    name.className = "dm-fp";
    name.textContent = peerLabel(item);

    const presence = doc.createElement("p");
    presence.className = "dm-presence";
    const label = actions.presenceOf(item.peer);
    const showDot = actions.presenceOn() && label !== "bilinmiyor";
    presence.dataset.state = actions.presenceOn() ? "on" : "off";

    if (showDot) {
      const dot = doc.createElement("span");
      dot.className = `dm-dot ${label === "çevrimiçi" ? "dm-dot--ok" : "dm-dot--idle"}`;
      dot.setAttribute("aria-hidden", "true");
      presence.append(dot);
    }
    const presenceText = doc.createElement("span");
    presenceText.className = "dm-presence-text";
    presenceText.textContent = label;
    presence.append(presenceText);

    threadHead.append(name, presence);

    const messages = doc.createElement("ol");
    messages.className = "dm-messages";
    if (item.messages.length === 0) {
      const cell = doc.createElement("li");
      const empty = doc.createElement("p");
      empty.className = "dm-empty";
      empty.textContent = "Bu konuşmada mesaj yok.";
      cell.append(empty);
      messages.append(cell);
    }
    for (const message of item.messages) appendMessage(doc, messages, message);

    const form = doc.createElement("form");
    form.className = "dm-compose";
    form.setAttribute("autocomplete", "off");

    const modes = doc.createElement("fieldset");
    modes.className = "dm-modes";
    const legend = doc.createElement("legend");
    legend.className = "dm-caption";
    legend.textContent = "Mod";

    const modeChoice = (value: DmMode, text: string): HTMLElement => {
      const option = doc.createElement("label");
      option.className = "dm-mode";
      const radio = doc.createElement("input");
      radio.type = "radio";
      radio.setAttribute("name", "dm-mode");
      radio.value = value;
      radio.checked = actions.modeOf() === value;
      radio.addEventListener("change", () => actions.setMode(value));
      option.append(radio, text);
      return option;
    };

    modes.append(legend, modeChoice("hizli", "Hızlı"), modeChoice("sessiz", "Sessiz"));

    const modeNote = doc.createElement("p");
    modeNote.className = "dm-mode-note";
    modeNote.textContent = MODE_NOTE[actions.modeOf()];

    // The ask-once row. It is the only place in the client that interrupts a
    // choice, and it only does so on the first downgrade to Hızlı.
    const modeAsk = doc.createElement("div");
    modeAsk.className = "dm-mode-ask";
    modeAsk.hidden = !actions.askModeOn();
    const askText = doc.createElement("p");
    askText.className = "dm-mode-ask-text";
    askText.textContent = FAST_ASK;
    const askRow = doc.createElement("div");
    askRow.className = "dm-mode-ask-row";
    const askYes = doc.createElement("button");
    askYes.type = "button";
    askYes.className = "dm-mode-ask-yes";
    askYes.textContent = "Hızlı kullan";
    askYes.addEventListener("click", () => actions.confirmFastMode());
    const askNo = doc.createElement("button");
    askNo.type = "button";
    askNo.className = "dm-mode-ask-no";
    askNo.textContent = "Sessiz kal";
    askNo.addEventListener("click", () => actions.cancelFastMode());
    askRow.append(askYes, askNo);
    modeAsk.append(askText, askRow);

    const fieldLabel = doc.createElement("label");
    fieldLabel.className = "dm-label";
    fieldLabel.append("Mesaj");

    const input = doc.createElement("textarea");
    input.className = "dm-input";
    input.rows = 2;
    input.value = actions.draftText();
    input.setAttribute("maxlength", String(MAX_BODY));
    input.setAttribute("spellcheck", "false");
    fieldLabel.append(input);

    const row = doc.createElement("div");
    row.className = "dm-compose-row";

    const counter = doc.createElement("span");
    counter.className = "dm-count";
    counter.textContent = `${actions.draftText().length} / ${MAX_BODY}`;

    const send = doc.createElement("button");
    send.type = "submit";
    send.className = "dm-send";
    send.textContent = "Mesaj gönder";

    row.append(modes, counter, send);

    const line = doc.createElement("p");
    line.className = "dm-status";
    line.setAttribute("role", "status");
    line.setAttribute("aria-live", "polite");
    status = line;

    // The field first, then one control row: mode, count, send. A visitor
    // arrives to write, not to choose a delivery mode, so the switch never sits
    // above the caret; and keeping it on the send row saves 71px that the
    // conversation gets instead — the composer was taller than the thread.
    form.append(fieldLabel, row, modeNote, modeAsk, line);

    input.addEventListener("input", () => actions.setDraft(input.value));
    form.addEventListener("submit", (event: Event) => {
      event.preventDefault();
      void actions.submit();
    });

    composer = { input, counter, send };
    thread.replaceChildren(threadHead, messages, form);
    renderComposer();
  }

  function renderComposer(): void {
    if (composer === null) return;
    const text = actions.draftText();
    if (composer.input.value !== text) composer.input.value = text;
    composer.counter.textContent = `${text.length} / ${MAX_BODY}`;
    composer.send.disabled = text.trim() === "" || actions.selectedPeer() === null;
  }

  function render(): void {
    renderList();
    renderThread();
    toggle.checked = actions.presenceOn();
  }

  function setStatus(message: string): void {
    if (status !== null) status.textContent = message;
  }

  return { render, renderComposer, setStatus };
}

/** One message row: mono clock, text, indent for own messages. Never a bubble. */
function appendMessage(doc: Document, parent: HTMLElement, message: DmMessage): void {
  const row = doc.createElement("li");
  row.className = "dm-msg";
  row.dataset.self = message.self ? "1" : "0";

  const clock = doc.createElement("time");
  clock.className = "dm-clock";
  if (Number.isFinite(message.at) && message.at > 0) {
    clock.setAttribute("datetime", new Date(message.at).toISOString());
  }
  clock.textContent = clockLabel(message.at);

  const text = doc.createElement("p");
  text.className = "dm-text";
  text.textContent = message.text;

  row.append(clock, text);
  parent.append(row);
}
