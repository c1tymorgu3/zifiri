/**
 * The four states every surface owes the user (`docs/spec.md` §Work order).
 *
 * Empty and error are sentences, not illustrations; loading is a skeleton of
 * the thing that is coming, so the page does not jump when it arrives. No
 * spinners: a spinner says "wait" without saying what for.
 *
 * Every string goes in through `textContent`.
 */
import "../styles/states.css";

export interface NoticeAction {
  readonly label: string;
  readonly run: () => void;
}

export interface Notice {
  readonly title: string;
  readonly body: string;
  readonly action?: NoticeAction;
  /** An extra, quieter way out. A demo link is the usual one. */
  readonly link?: { readonly label: string; readonly href: string };
}

function el<K extends keyof HTMLElementTagNameMap>(
  doc: Document,
  tag: K,
  className: string,
  text?: string,
): HTMLElementTagNameMap[K] {
  const node = doc.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

/** Loading: rows of the shape that is about to arrive. */
export function renderSkeleton(mount: HTMLElement, rows = 5): void {
  const doc = mount.ownerDocument;
  const wrap = el(doc, "div", "zf-skeleton");
  wrap.setAttribute("aria-busy", "true");
  wrap.setAttribute("aria-label", "loading");

  for (let index = 0; index < rows; index += 1) {
    const row = el(doc, "div", "zf-skeleton-row");
    const line = el(doc, "span", "zf-skeleton-line");
    line.style.setProperty("--zf-skeleton-width", `${88 - ((index * 17) % 46)}%`);
    row.append(line);
    wrap.append(row);
  }

  mount.replaceChildren(wrap);
}

/** Empty, error and offline: a reason and the next step, nothing else. */
export function renderNotice(mount: HTMLElement, notice: Notice): void {
  const doc = mount.ownerDocument;
  const wrap = el(doc, "section", "zf-state");

  wrap.append(
    el(doc, "h2", "zf-state-title", notice.title),
    el(doc, "p", "zf-state-body", notice.body),
  );

  const actions = el(doc, "div", "zf-state-actions");

  if (notice.action !== undefined) {
    const button = el(doc, "button", "zf-state-action", notice.action.label);
    button.type = "button";
    button.addEventListener("click", () => notice.action?.run());
    actions.append(button);
  }

  if (notice.link !== undefined) {
    const link = el(doc, "a", "zf-state-link", notice.link.label);
    link.href = notice.link.href;
    actions.append(link);
  }

  if (actions.childNodes.length > 0) wrap.append(actions);

  mount.replaceChildren(wrap);
}

/** The persistent offline rule. It sits above the surface, not in a toast. */
export function renderOfflineRule(rule: HTMLElement, offline: boolean): void {
  if (!offline) {
    rule.setAttribute("hidden", "");
    rule.textContent = "";
    return;
  }
  rule.removeAttribute("hidden");
  rule.textContent = "No connection. Writing is off; try again when it returns.";
}
