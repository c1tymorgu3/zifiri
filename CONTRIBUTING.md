# Contributing

zifiri is licensed under the AGPL-3.0 (`LICENSE`). Sending a patch means you agree it ships under that
license; there is no CLA and no copyright assignment.

## Every change passes these four

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test
cd client && npm test
```

Run them before you open a pull request; CI runs exactly the same four. `mix format` on its own is fine
locally. Do not silence a warning with `@moduledoc false`, `_ =` on an unused result, or a dialyzer
ignore — the tree is warning-clean and stays that way. A behaviour change without a test is not done:
the test is the evidence that the promise still holds.

## Two questions before you add anything

### Adding a column: does it link two posts to one person?

Any column that groups rows by author, device, session, or network, or that survives a delete and
still points at the same writer, is a deanonymisation channel. If the answer is yes, the column does
not go in. "We'll hash it" is not an answer — a hash of a stable input is a stable identifier. If you
cannot say what the column is for without naming its owner, it is the wrong column.

### Adding a dependency: does it make a third-party request from the browser?

Fonts from a CDN, analytics, telemetry, error reporting, update checks, a preconnect, a favicon
fetched from somewhere else — each one hands a visitor's IP to a third party and each one needs a CSP
exception. If the answer is yes, the dependency does not go in. Server-side dependencies are held to
the same bar as `mix.exs`: nothing that logs requests, resolves addresses, or ships telemetry.
Prefer the standard library, then an existing dependency, then nothing.

The same rule applies to `mix.exs` and `client/package.json` alike; a new entry there is a design
decision, not a convenience.

## Commit messages

Short, neutral, about the change — what it does, in the imperative, one line, no body if the diff
speaks for itself.

```
add batch pool floor check
drop session id from chat frames
fix WAL truncation after delete
```

No agent or tool attribution: no `Co-Authored-By: <agent>`, no "Generated with ...", no emoji, no
"comprehensive" or "robust". The history should read like it was written by whoever wrote the code.
Squash the fixups; one commit per idea.

## What gets closed without review

- Patches that add a column, a dependency, or an outbound request without answering the question above.
- Formatting-only changes mixed into a behavioural one.
- Anything that touches the threat model, the log table, or the deletion path without a test that
  fails before the patch.
- Commits that include `zifiri_dev.db`, `_build/`, `deps/`, or a key of any kind.

## Docs

`docs/plan.md` is the contract; code that disagrees with it is a bug, not a doc update. If a patch
changes a promise, change the plan in the same commit and say so in the message. Prose docs are in
Turkish, code, comments, commit messages, and these repository files are in English.
