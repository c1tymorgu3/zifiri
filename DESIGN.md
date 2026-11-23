# DESIGN.md

Mode: **Operate**. The visitor is completing a task, not being persuaded. Ambition
shows as precision, not spectacle.

## Visual world

**Kamu hizmeti, 2026.** A public notice board rebuilt by someone who cares about
typography. Paper-white type on near-black, a single amber accent used only for
action, hairline rules instead of cards, and numbers set in tabular figures so
timestamps line up. It should feel like a municipal terminal that happens to be
beautiful — not like a hacker movie.

Anti-references, banned outright: matrix green, glitch text, skulls, hoodies,
"anonymous" masks, neon glow, terminal scanlines, padlocks as decoration,
`>_` prompt motifs, l33t speak, and any copy that performs danger.

## Colour

| token | value | use |
|---|---|---|
| `--bg` | `#0B0C0E` | page |
| `--surface` | `#121417` | raised rows, inputs |
| `--fg` | `#F2F3F5` | primary text (16.9:1) |
| `--muted` | `#9AA0A8` | metadata (7.1:1) |
| `--line` | `#24272C` | hairlines, dividers |
| `--accent` | `#E8A33D` | primary action, active room, focus |
| `--danger` | `#D9534F` | destructive only, never decorative |
| `--ok` | `#4FA86A` | presence, success |

Rules: accent never carries text on accent (always dark text on amber). Colour
never the only signal — pair with weight, glyph or text. Max one accent element
per viewport region.

## Type

- Stack: `-apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif`
  for UI; `ui-monospace, "SF Mono", Menlo, Consolas, monospace` for identifiers,
  amounts, timestamps and the identity string.
- Scale: 12 / 13 / 15 / 18 / 24 / 32. Body 15, line-height 1.6. Headings 1.25.
- Weights: 400 body, 500 UI labels, 600 headings only.
- Max measure 68ch. Tabular numerals in every table, price, count and clock.

## Layout

- 8px baseline; spacing steps 4 / 8 12 / 16 / 24 / 32 / 48.
- Desktop: 1040px content, three surfaces as a left rail (96px icon+label) and
  content column. Mobile: bottom tab bar, one column, 16px gutters.
- Rules, not boxes: 1px `--line` separators; borders only on inputs and the
  destructive zone.
- Density: listing rows 56px, message rows 44px, room rows 48px.

## Components

- **Room row**: name, last activity in relative time ("3 dk"), unread count,
  presence dot only if presence is enabled. Active row: amber 2px left rule.
- **Message**: text, monospace clock, no avatar, no name. Decoys are
  indistinguishable — no marker, no spacing difference, no opacity change.
- **Listing card**: title (600), price in tabular mono, category chip (hairline),
  day. No seller block, because there is no seller field.
- **Composer**: single textarea, char counter, mode switch (Hızlı / Sessiz) with
  a one-line consequence sentence, send button amber.
- **Identity**: the `zifir1...` string in mono, 8-character fingerprint, copy
  button, and the sentence "Bu satırı kaybedersen kimliğin gider."
- **Danger zone**: `--danger` border, no icon, phrase confirmation typed by hand.

## Motion

120ms ease-out for state changes, 180ms for panel entry, nothing else. No
parallax, no glow pulses, no typing indicators that fake activity. Respect
`prefers-reduced-motion`: all transitions become opacity-only, 0ms.

## States (designed, not defaulted)

Empty: one sentence explaining why it is empty, no illustration.
Loading: static skeleton rows with hairline placeholders, no spinners.
Error: what failed, what to do, no error codes visible to the user.
Offline: persistent top rule, "bağlantı yok", retry is manual.
Rate-limited (PoW): a progress bar with the real attempt count, cancellable.

## Accessibility

Focus visible on every interactive element (2px amber offset ring). Hit targets
≥44px. Contrast: primary ≥7:1, muted ≥4.5:1. Every icon has a text label in
the DOM. Tab order follows reading order. No keyboard trap in the composer.

## Copy

Turkish, second person, no exclamation marks. Verbs first: "İlan ver",
"Mesaj gönder", "Yok ol". Error copy states the cause in one clause and the
next action in another. Never blame the user, never say "Oops".
