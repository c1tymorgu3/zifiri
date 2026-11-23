import { describe, expect, it } from "vitest";
import {
  FINGERPRINT_LENGTH,
  renderShell,
  ShellError,
  SURFACES,
  type Shell,
  type Surface,
  type SurfaceId,
} from "../src/shell";

// ---------------------------------------------------------------------------
// Minimal fake DOM, the same shape the other view tests use: createElement,
// append/replaceChildren, attributes, listeners, and document-level keydown so
// the shell's shortcuts can be exercised the way a keyboard user would.
// ---------------------------------------------------------------------------

type Handler = (event: FakeEvent) => void;

interface FakeEvent {
  key?: string;
  target?: FakeEl | null;
  altKey?: boolean;
  ctrlKey?: boolean;
  metaKey?: boolean;
  defaultPrevented: boolean;
  preventDefault(): void;
}

class FakeEl {
  className = "";
  textContent = "";
  children: (FakeEl | string)[] = [];
  attrs: Record<string, string> = {};
  listeners: Record<string, Handler[]> = {};
  id = "";
  name = "";
  value = "";
  checked = false;
  type = "";
  rows = 0;
  scrollTop = 0;
  scrollHeight = 0;
  parent: FakeEl | null = null;
  focused = false;

  readonly tagName: string;

  constructor(tag: string, readonly ownerDocument: FakeDoc) {
    // The DOM uppercases HTML tag names, and `isEditable` reads them as such.
    this.tagName = tag.toUpperCase();
  }

  append(...nodes: (FakeEl | string)[]): void {
    for (const node of nodes) {
      this.children.push(node);
      if (node instanceof FakeEl) node.parent = this;
    }
  }

  replaceChildren(...nodes: (FakeEl | string)[]): void {
    this.children = [];
    this.append(...nodes);
  }

  remove(): void {
    if (this.parent !== null) {
      this.parent.children = this.parent.children.filter((child) => child !== this);
      this.parent = null;
    }
  }

  setAttribute(name: string, value: string): void {
    this.attrs[name] = value;
    // An SVG icon is labelled with `class="..."`; the attribute is the class.
    if (name === "class") this.className = value;
  }

  getAttribute(name: string): string | null {
    return this.attrs[name] ?? null;
  }

  removeAttribute(name: string): void {
    delete this.attrs[name];
  }

  hasAttribute(name: string): boolean {
    return name in this.attrs;
  }

  addEventListener(type: string, handler: Handler): void {
    const list = this.listeners[type] ?? [];
    list.push(handler);
    this.listeners[type] = list;
  }

  removeEventListener(type: string, handler: Handler): void {
    this.listeners[type] = (this.listeners[type] ?? []).filter((entry) => entry !== handler);
  }

  focus(): void {
    this.focused = true;
  }

  fire(type: string): void {
    let prevented = false;
    const event: FakeEvent = {
      defaultPrevented: false,
      preventDefault() {
        prevented = true;
        event.defaultPrevented = true;
      },
    };
    for (const handler of this.listeners[type] ?? []) handler(event);
    if (type === "submit" && !prevented) throw new Error("submit was not prevented");
  }

  text(): string {
    return (
      this.textContent +
      this.children.map((child) => (typeof child === "string" ? child : child.text())).join("")
    );
  }
}

class FakeDoc {
  listeners: Record<string, Handler[]> = {};

  createElement(tag: string): FakeEl {
    return new FakeEl(tag, this);
  }

  createElementNS(_namespace: string, tag: string): FakeEl {
    return new FakeEl(tag, this);
  }

  addEventListener(type: string, handler: Handler): void {
    const list = this.listeners[type] ?? [];
    list.push(handler);
    this.listeners[type] = list;
  }

  removeEventListener(type: string, handler: Handler): void {
    this.listeners[type] = (this.listeners[type] ?? []).filter((entry) => entry !== handler);
  }

  fireKey(
    key: string,
    target: FakeEl | null = null,
    extra: { altKey?: boolean; ctrlKey?: boolean; metaKey?: boolean } = {},
  ): FakeEvent {
    const event: FakeEvent = {
      key,
      target,
      altKey: extra.altKey ?? false,
      ctrlKey: extra.ctrlKey ?? false,
      metaKey: extra.metaKey ?? false,
      defaultPrevented: false,
      preventDefault() {
        event.defaultPrevented = true;
      },
    };
    for (const handler of [...(this.listeners["keydown"] ?? [])]) handler(event);
    return event;
  }
}

function root(): FakeEl {
  return new FakeEl("div", new FakeDoc());
}

function all(node: FakeEl, className: string): FakeEl[] {
  const found: FakeEl[] = [];
  const walk = (current: FakeEl): void => {
    if (current.className.split(/\s+/).includes(className)) found.push(current);
    for (const child of current.children) {
      if (typeof child !== "string") walk(child);
    }
  };
  walk(node);
  return found;
}

function one(node: FakeEl, className: string): FakeEl {
  const [first] = all(node, className);
  if (first === undefined) throw new Error(`missing .${className}`);
  return first;
}

function mount(): FakeEl {
  return root();
}

function shellOn(
  options: {
    active?: SurfaceId;
    surfaces?: readonly Surface[];
    identity?: { fingerprint: string } | null;
  } = {},
): { shell: Shell; mount: FakeEl; navigated: SurfaceId[] } {
  const host = mount();
  const navigated: SurfaceId[] = [];
  const shell = renderShell(host as unknown as HTMLElement, {
    ...(options.surfaces === undefined ? {} : { surfaces: options.surfaces }),
    active: options.active ?? "rooms",
    onNavigate: (id) => navigated.push(id),
    ...(options.identity === undefined ? {} : { identity: options.identity }),
  });
  return { shell, mount: host, navigated };
}

function tabs(host: FakeEl): FakeEl[] {
  return all(host, "zf-tab");
}

function tabFor(host: FakeEl, id: SurfaceId): FakeEl {
  const found = tabs(host).find((tab) => tab.getAttribute("data-surface") === id);
  if (found === undefined) throw new Error(`missing tab for ${id}`);
  return found;
}

// ---------------------------------------------------------------------------

describe("shell", () => {
  it("draws one tab per surface, each with an icon and a text label", () => {
    const { mount: host } = shellOn();

    const drawn = tabs(host);
    expect(drawn).toHaveLength(3);
    expect(drawn.map((tab) => one(tab, "zf-tab-label").textContent)).toEqual([
      "Rooms",
      "Messages",
      "Listings",
    ]);

    for (const tab of drawn) {
      const icon = one(tab, "zf-tab-icon");
      expect(icon.children.length).toBeGreaterThan(0);
      expect(icon.getAttribute("aria-hidden")).toBe("true");
    }
  });

  it("marks exactly one tab as the current page", () => {
    const { mount: host } = shellOn({ active: "messages" });

    const current = tabs(host).filter((tab) => tab.getAttribute("aria-current") === "page");
    expect(current).toHaveLength(1);
    expect(current[0]?.getAttribute("data-surface")).toBe("messages");
  });

  it("navigates on click and moves the mark with it", () => {
    const { mount: host, navigated, shell } = shellOn();

    tabFor(host, "listings").fire("click");

    expect(navigated).toEqual(["listings"]);
    expect(shell.active()).toBe("listings");
    expect(tabFor(host, "listings").getAttribute("aria-current")).toBe("page");
    expect(tabFor(host, "rooms").getAttribute("aria-current")).toBeNull();
  });

  it("does not navigate again when the current surface is clicked", () => {
    const { mount: host, navigated } = shellOn({ active: "rooms" });

    tabFor(host, "rooms").fire("click");

    expect(navigated).toEqual([]);
  });

  it("navigates with 1 / 2 / 3", () => {
    const { mount: host, navigated } = shellOn();
    const doc = host.ownerDocument;

    doc.fireKey("2");
    doc.fireKey("3");
    doc.fireKey("1");

    expect(navigated).toEqual(["messages", "listings", "rooms"]);
  });

  it("leaves the number keys alone while the writer is typing", () => {
    const { mount: host, navigated } = shellOn();
    const textarea = new FakeEl("textarea", host.ownerDocument);

    const event = host.ownerDocument.fireKey("2", textarea);

    expect(navigated).toEqual([]);
    expect(event.defaultPrevented).toBe(false);
  });

  it("ignores modified key presses", () => {
    const { mount: host, navigated } = shellOn();
    const doc = host.ownerDocument;

    doc.fireKey("2", null, { ctrlKey: true });
    doc.fireKey("2", null, { altKey: true });
    doc.fireKey("2", null, { metaKey: true });

    expect(navigated).toEqual([]);
  });

  it("follows the order the surfaces were given for the shortcuts", () => {
    const { mount: host, navigated } = shellOn({
      surfaces: [
        { id: "listings", label: "Listings" },
        { id: "rooms", label: "Rooms" },
        { id: "messages", label: "Messages" },
      ],
    });

    host.ownerDocument.fireKey("1");
    expect(navigated).toEqual(["listings"]);
    expect(tabFor(host, "listings").getAttribute("aria-keyshortcuts")).toBe("1");
  });

  it("moves the mark without navigating when the caller sets the surface", () => {
    const { mount: host, navigated, shell } = shellOn();

    shell.setActive("messages");

    expect(navigated).toEqual([]);
    expect((shell.root as unknown as FakeEl).getAttribute("data-active")).toBe("messages");
    expect(tabFor(host, "messages").getAttribute("aria-current")).toBe("page");
  });

  it("refuses a surface it was never given", () => {
    const { shell } = shellOn();

    expect(() => shell.setActive("yok" as unknown as SurfaceId)).toThrow(ShellError);
  });

  it("refuses an empty or duplicated surface list", () => {
    const host = mount();

    expect(() =>
      renderShell(host as unknown as HTMLElement, {
        surfaces: [],
        active: "rooms",
        onNavigate: () => undefined,
      }),
    ).toThrow(ShellError);

    expect(() =>
      renderShell(host as unknown as HTMLElement, {
        surfaces: [
          { id: "rooms", label: "Rooms" },
          { id: "rooms", label: "Yine odalar" },
        ],
        active: "rooms",
        onNavigate: () => undefined,
      }),
    ).toThrow(ShellError);
  });

  it("shows the first eight characters of the fingerprint", () => {
    const { mount: host } = shellOn({ identity: { fingerprint: "zifir1deadbeefcafe" } });

    const value = one(host, "zf-identity-value");
    expect(value.textContent).toBe("zifir1de");
    expect(value.textContent).toHaveLength(FINGERPRINT_LENGTH);
    // The full string is still available on hover, not in the label.
    expect(one(host, "zf-identity").getAttribute("title")).toBe("zifir1deadbeefcafe");
  });

  it("says there is no identity instead of drawing a placeholder key", () => {
    const { mount: host, shell } = shellOn({ identity: null });

    expect(one(host, "zf-identity-value").textContent).toBe("—");
    expect(one(host, "zf-identity").getAttribute("data-state")).toBe("none");

    shell.setIdentity({ fingerprint: "abcdef0123456789" });
    expect(one(host, "zf-identity-value").textContent).toBe("abcdef01");
    expect(one(host, "zf-identity").getAttribute("data-state")).toBe("set");
  });

  it("stops listening for keys after destroy", () => {
    const { mount: host, shell, navigated } = shellOn();

    shell.destroy();
    host.ownerDocument.fireKey("2");

    expect(navigated).toEqual([]);
    expect(host.children).toHaveLength(0);
  });

  it("renders the surface content into its own main region", () => {
    const { shell } = shellOn();
    const content = new FakeEl("section", (shell.main as unknown as FakeEl).ownerDocument);

    shell.setContent(content as unknown as Node);
    expect((shell.main as unknown as FakeEl).children).toContain(content);

    shell.setContent(null);
    expect((shell.main as unknown as FakeEl).children).toHaveLength(0);
  });

  it("exports the three surfaces in rail order", () => {
    expect(SURFACES.map((surface) => surface.label)).toEqual(["Rooms", "Messages", "Listings"]);
  });
});
