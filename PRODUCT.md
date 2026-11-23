# PRODUCT.md

> Assumed from the user's brief, not from an interview. Two assumptions are
> marked **[ASSUMED]**; everything else is stated by the brief.

## What this is

zifiri is a small, self-hosted board with three surfaces and no accounts:

1. **Odalar** — one public room where messages live in a 500-line buffer for 15
   minutes and are never written to disk.
2. **Mesajlar** — one-to-one messages, sealed to the recipient's key; the
   server stores no sender.
3. **İlanlar** — a classifieds board where the seller has no account, no email
   and no profile.

The claim is not secrecy of content. The claim is that there is no person to
point at: no signup, no login, no cookie, no IP log, no admin panel that can
answer "who wrote this". The numbers behind that sentence are in
`docs/claims.md`, each one next to the command that reproduces it.

## Who it is for

People who need to publish without an account behind them: a seller who does not
want a phone number scraped, a neighbour asking a question that would identify
them, someone who cannot put their name on a line. They are not technologists.
They will use it on a phone, once or twice, and leave.

What they publish is their decision and their operator's; this repository is
about the identification, not the content.

**[ASSUMED]** Turkish-first, English second. The copy is Turkish; the code and
docs are English.

## What success looks like

- A first-time visitor understands all three surfaces in under 20 seconds and
  posts within two minutes without reading help.
- Nobody is ever asked for an email, a phone number, a username, or a password.
- The identity is one 71-character string; losing it is a documented
  consequence, not a support ticket.
- Deleting is one page, two clicks, and it is *finished*: no tombstone, no
  backup copy, no "your data may persist for 30 days".
- Every security claim on the site links to a command that proves it.

## Non-goals

- Not a social network: no follows, no likes, no profiles, no public history.
- Not a marketplace with payments, escrow, shipping or ratings. Listings are
  text; the transaction happens outside the product.
- Not a content-policy document. What an instance publishes is its operator's
  decision; this repository is about who can be identified.
- Not a mobile app. Web only; works on a phone browser.

## Constraints that shape everything

- No third-party request from the browser: no fonts, no analytics, no CDN.
- No JavaScript storage (localStorage/sessionStorage) for anything about a user.
- Bundle budget: 100 KiB gzip.
- The operator is outside the model: the design assumes compliance and minimises
  what compliance yields — ciphertext, hashes, and a bucket that says only "120
  arrived".
- Moderation is a separate plane with its own credential and no link to content.

## Voice

Plain, dry, specific. No menace, no hacker theatre, no "military-grade".
A sentence that a cautious civil servant would sign. The claim is stated at full
strength and without apology; a limit is written as a design boundary, not a
disclaimer.
