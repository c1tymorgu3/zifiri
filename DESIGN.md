# zifiri — design

**World: technical ledger.** The product is an anonymous board you consult, not
a feed you scroll. It is drawn the way a survey office draws: a ruled page, one
column of clocks, numbers set in a face meant for numbers, and no decoration
that does not carry information. Restraint here is not a style; it is the
argument the product makes about itself — nothing collected, nothing shown that
was not given.

Mode of use: **operate**. Someone reads a room in one pass, posts, closes the
tab. The page therefore optimises for scanning and for a calm, exact surface —
not for delight, not for presence.

## Type

| Role | Face | Size | Weight |
| --- | --- | --- | --- |
| Screen title | IBM Plex Sans | 24px | 600 |
| Body, message, field value | IBM Plex Sans | 15px | 400 |
| Secondary, sentence-length state | IBM Plex Sans | 13px | 400 |
| Field and column labels | IBM Plex Sans | 11px | 400, tracked `.08em`, uppercase |
| Clocks, counters, ids, prices, dates, measurements | IBM Plex Mono | 11–15px | 400 |

Four sizes, no fifth. There is no 18px, no 32px, no intermediate step.

**Monospace is reserved for data.** A clock, a fingerprint, an unread count, a
price, a date, a character counter, a queue measurement: these are values, and
the mono face keeps their columns from drifting. A *label* is prose, so it is
set in the text face. Dressing a section heading in mono to look technical is
forbidden — it is costume, not information.

Two voices, self-hosted, latin + latin-ext, so a Turkish word never falls back
mid-word:

```
client/public/fonts/ibm-plex-sans-latin.woff2        (variable, 400–700)
client/public/fonts/ibm-plex-sans-latin-ext.woff2
client/public/fonts/ibm-plex-mono-400-latin.woff2
client/public/fonts/ibm-plex-mono-400-latin-ext.woff2
client/public/fonts/ibm-plex-mono-700-latin.woff2
client/public/fonts/ibm-plex-mono-700-latin-ext.woff2
```

Nothing is requested from a third party. CSP is `font-src 'self'`, and the
font files are in the `Plug.Static` allowlist beside `assets`.

## Palette

Six values. They exist in `client/src/styles/tokens.css` on `:root` and nowhere
else — no surface may re-declare a colour, a size or a step.

| Token | Value | Role |
| --- | --- | --- |
| `--bg` | `#0b0c0d` | the page |
| `--surface` | `#101214` | a hovered row, a skeleton block — one step off the page, never a card |
| `--line` | `#1e2124` | every hairline: row rules, column rules, the frame |
| `--fg` | `#e8e6e1` | text |
| `--muted` | `#8b9096` | labels, clocks, secondary sentences |
| `--accent` | `#e8a33d` | **only** the current section, keyboard focus, and a state that is changing |
| `--danger` | `#c2564a` | offline, over-limit, destructive |

**The accent is not a decoration budget.** It appears as: a 2px rule in the
gutter of the current nav item, the underline of the selected delivery mode,
the fill of a queue tick, a self-authored clock, the focus ring, the caret, the
selection. If a block is merely present it gets no colour. No accent fills, no
accent buttons, no accent headings.

Selection, caret and scrollbar are themed from the same set: selection is
`--accent` on `--bg`, the caret is `--accent`, scrollbars are thin with a
`--line` thumb that lifts to `--muted` on hover. A default blue selection or a
light scrollbar trough is the fastest way to look unfinished.

## Layout

- **Rows, not cards.** Lists are registers: 44–56px tall, one 1px `--line` rule
  between neighbours, full-bleed to the column edge. No element in a list has a
  border on all four sides.
- **Columns align.** A listing row is `title | category | day | price` on fixed
  tracks; the price and the day are right-aligned and stay on their track from
  row to row. Numbers use `font-variant-numeric: tabular-nums` globally.
- **One gutter column for time.** Message threads put the clock in a fixed
  44px left column and the sentence in the text column, so the eye scans one
  column of times and one of prose. Messages that do not fill the thread rest on
  the composer, not in the middle of the page.
- **One column of measure.** Surfaces cap at 1080px and centre in the main
  area; prose caps at 68ch.
- **Corners are square.** `--radius: 2px` is the maximum anywhere; buttons,
  inputs, the identity value block, chips.
- **Rows carry state with a gutter rule**, not a filled block: the current room,
  conversation and nav item each show a 2px accent rule at their leading edge.

## Surfaces

- **Rooms** — a 216px index of 48px room rows (name, clock, unread, the word
  "active" where a dot used to be) beside a thread: 24px room title, 13px
  subtitle, 48px logbook rows, and a composer that is a ruled writing line, two
  text modes with an accent underline, the anonymity readout in mono, the
  counter, and an outlined Send.
- **Messages** — a 300px conversation register (mono peer id, one line of the
  last message, clock, unread) beside the same logbook thread, a presence line
  in words, and a composer with modes, a "leaves your write moment hidden"
  sentence and an outlined Send.
- **Listings** — a real table: 24px title, a ruled filter strip of cells, then
  52px rows with a fixed price column. The detail is a measured column with a
  24px title and a meta line; the new-listing form is a stack of ruled lines,
  not a panel.
- **Identity** — a 640px sheet: the identity string in a bordered value block,
  fingerprint in mono, import as a ruled input, and the destructive block
  introduced by a `--danger` rule rather than a red panel.

## Motion

120ms, `ease-out`, on colour, border-colour and background only. No transform
the eye must follow, no bounce, no parallax, no skeleton shimmer (a sweep is a
gradient in motion). `prefers-reduced-motion` sets every duration to 0.

## Forbidden

No `box-shadow`. No gradient, of any kind, anywhere. No `backdrop-filter` or
glass. No emoji. No radius above 2px. No pill-shaped tags. No icon-only
navigation. No kicker or eyebrow label above a heading — a heading carries its
own weight. No section numbers (`01 / 02 / 03`) used as ornament: order must
mean order. No monospace on a label that is not a value. No status dot where a
word will do. No third-party font, image or script. No colour outside the seven
above.

## Verification

```
cd client && npx tsc --noEmit && npx vitest run && npm run build
node scripts/size.mjs                     # JS gzip under 100 KiB
impeccable detect --json client/src       # must print []
```

Screenshots of record (1280×900 desktop, 390×844 phone) live in `docs/shots/`:
`v2-rooms-1280.png`, `v2-messages-1280.png`, `v2-listings-1280.png`,
`v2-listings-390.png`.
