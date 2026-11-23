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
add queue floor check
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

## CI jobs

`make check` is three commands (`mix format --check-formatted`,
`mix compile --warnings-as-errors`, `mix test`); CI is six jobs, each one a question with an exit code. If a job is
green, the sentence on the right was executed against that commit.

- **`elixir`** — format check, `mix compile --force --warnings-as-errors`, `mix test` on the OTP and
  Elixir versions pinned in `.tool-versions`.
- **`client`** — `npm ci`, `tsc --noEmit`, `vitest run`, `npm run build`, and a bundle-size check
  under 100 KiB gzip.
- **`architecture`** — greps over `lib/`, `test/` and `infra/`: no `Logger.info`/`IO.inspect`/`dbg(`,
  no peer or proxy header read outside `lib/zifiri/transport.ex`, no Ecto `log:`, nginx
  `access_log off`, container `USER`/`read_only`/`no-new-privileges`.
- **`claims`** — both `docs/claims.md` and `docs/verify.md` carry the same `C-01`…`C-49` IDs with no
  gap, and the README cites no ID that `claims.md` does not define.
- **`docs`** — every relative link in `README.md` and `docs/*.md` resolves to a file in the tree.
- **`e2e`** — a real Chrome against a running `mix phx.server` loads `/`, `/?demo=1` and
  `/?demo=1&surface=listings` and asserts on the DOM; gated by a `test -f` job so a fork without
  `scripts/e2e/run.sh` shows **skipped**, not green.

`docs/ci.md` has the details, the cache keys, the timings, and what is deliberately left to a live
host.

## Browser pass

`test/` runs the server in-process and `vitest` runs the client in jsdom; neither one loads the
built bundle in a browser. `docs/e2e.md` is that missing link.

```bash
make static && scripts/e2e/run.sh      # headless Chrome, --dump-dom + --screenshot, ~10 s
```

The script reuses a server already answering `/health` on port 4000 and starts its own only if none
is there; it exits `2` if something else owns the port. Three scenarios: the shell draws three rail
tabs, `/?demo=1` renders the demo badge and the fixture rows, and `/?demo=1&surface=listings`
renders the listing list. Any console message from the page fails the run. Exit codes: `0` pass,
`1` a check failed, `2` the environment is wrong.

`ZIFIRI_E2E_PORT=4010` moves the port, `ZIFIRI_E2E_KEEP=1` keeps the DOM dumps, `CHROME=` points at
a browser. The plain-HTTP variant is `mix test --include integration test/e2e_test.exs` against a
running server; it is excluded from `mix test` so the default suite stays offline.

## Docs

`docs/spec.md` is the contract; code that disagrees with it is a bug, not a doc update. If a patch
changes a promise, change the spec in the same commit and say so in the message. Every claim is tied
to a `C-nn` ID in `docs/claims.md` and to a runnable command in `docs/verify.md`; numbers live in
`docs/measurements.md`, and the reasons behind the design in `docs/decisions.md`.

Every repository file is in English — README, `docs/`, code, comments, commit messages. A Turkish
comment or a French sentence in a doc is a bug like any other.
