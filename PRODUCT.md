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

The point is not secrecy of content — it is the absence of a person to point
at. There is no signup, no login, no cookie, no IP log, no admin panel that can
answer "who wrote this".

## Who it is for

People who need to post something without leaving a trace: a worker reporting
conditions, a seller who does not want their phone number scraped, someone in a
small town asking a question that would identify them. They are not
technologists. They will use it on a phone, once or twice, and leave.

**[ASSUMED]** Turkish-first, English second. The copy is Turkish; the code and
docs are English.

## What success looks like

- A first-time visitor understands all three surfaces in under 20 seconds and
  posts within two minutes without reading help.
- Nobody is ever asked for an email, a phone number, a username, or a password.
- The identity is one string the user can write on paper, and losing it is a
  documented, honest consequence — not a support ticket.
- Deleting is one page, two clicks, and it is *finished*: no tombstone, no
  backup copy, no "your data may persist for 30 days".
- Every security claim on the site links to a command that proves it.

## Non-goals

- Not a social network: no follows, no likes, no profiles, no public history.
- Not a marketplace with payments, escrow, shipping or ratings. Listings are
  text; the deal happens elsewhere, at the users' own risk.
- Not a leak dump or a place to point at people. Content policy: no personal
  data about third parties, no targeting. That is a product rule, enforced in
  moderation, not a moral lecture on the homepage.
- Not a mobile app. Web only; works on a phone browser.

## Constraints that shape everything

- No third-party request from the browser: no fonts, no analytics, no CDN.
- No JavaScript storage (localStorage/sessionStorage) for anything about a user.
- Bundle budget: 100 KiB gzip.
- The operator is not trusted with identity, only with ciphertext and hashes.
- Moderation is a separate plane with its own credential and no link to content.

## Voice

Plain, dry, specific. No menace, no hacker theatre, no "military-grade".
A sentence that a cautious civil servant would sign.
