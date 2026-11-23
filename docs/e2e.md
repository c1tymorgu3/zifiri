# zifiri — end-to-end (e2e.md)

The suite in `test/` exercises the server in-process and the client in `vitest`.
Neither one loads the built bundle in a browser and talks to a running server.
This document is that missing link: a real Chrome, a real `mix phx.server` on
`127.0.0.1`, and assertions on the DOM the browser actually produced.

Two entry points, one for each side of the gap:

| File | What it drives | Runtime |
| --- | --- | --- |
| `scripts/e2e/run.sh` | headless Chrome, `--dump-dom` and `--screenshot` | ~10 s |
| `test/e2e_test.exs` | plain HTTP against the same server | ~0.1 s |

---

## 1. How to run it

### 1.1 The browser run

```bash
make static          # client/dist -> priv/static, if it is not already fresh
scripts/e2e/run.sh
```

`run.sh` does the rest:

- if `http://127.0.0.1:4000/health` answers `{"status":"ok"}`, the running server
  is **left untouched** and nothing is killed at the end;
- otherwise it starts one itself (`ZIFIRI_E2E_PORT` or 4000), waits up to 90 s
  for `/health`, and stops only what it started;
- if the port answers but **not** with zifiri's `/health`, it exits `2` with the
  pid. That case is not hypothetical — a leftover `vite preview --port 4000`
  from `client/` answers every path with `index.html` and would make a naive
  script "pass" while testing the wrong process.

Options:

```bash
ZIFIRI_E2E_PORT=4010 scripts/e2e/run.sh     # another port (the app itself pins 4000)
ZIFIRI_E2E_KEEP=1 scripts/e2e/run.sh        # keep the DOM dumps after a pass
CHROME=/path/to/chrome scripts/e2e/run.sh   # CHROME_BIN and CHROME_PATH also work
```

Exit codes: `0` every check passed, `1` a check failed, `2` the environment is
wrong (no Chrome, foreign process on the port, server never became ready).

### 1.2 The HTTP run

```bash
ZIFIRI_E2E_PORT=4000 mix run --no-start scripts/e2e/serve.exs &   # if not already up
ZIFIRI_E2E_BASE=http://127.0.0.1:4000 mix test --include integration test/e2e_test.exs
```

`test/test_helper.exs` excludes `:integration`, so plain `mix test` stays
hermetic and offline. The tag is the only thing that keeps these out — there is
no skip logic: with the server down the four tests **fail**, each one naming the
command that starts it. A skipped E2E and a passing E2E look identical in a CI
summary; only one of them is true.

`scripts/e2e/serve.exs` exists because `config/config.exs` pins port 4000 and
`mix phx.server` gives no way to override it. It writes the port into the
endpoint config *before* the application starts (`mix run --no-start`), which is
the whole trick.

---

## 2. What the three scenarios assert

### a) `/` — the shell is drawn

| Check | How |
| --- | --- |
| `#app` is populated | `id="app"` **and** `class="zf-rail"` both in the dumped DOM |
| three tabs | exactly three `class="zf-tab"` |
| boot placeholder gone | no `zf-boot-note` — `main.ts` really replaced the skeleton in `index.html` |

The third check is the one that catches a bundle that 404s: the skeleton is
static HTML, so a page whose script never ran still shows three tabs. Only the
placeholder's absence proves the module executed.

### b) `/?demo=1` — sample data on screen

| Check | How |
| --- | --- |
| demo badge | `data-demo="true"` **and** the literal text `örnek veri` |
| rooms not empty | `class="zf-room"` count > 0 **and** the room `mahalle` present |
| listings not empty | `class="listing"` count > 0 |

Two details worth knowing:

- **The room check needs `mahalle`.** The live path renders one room (`lobi`)
  even against an empty store, so `count > 0` alone passes without demo mode.
  `mahalle` exists only in `client/src/demo/fixtures.ts`, so seeing it is what
  proves the fixtures — not the live API — reached the DOM.
- **Listings are checked on `/?demo=1&surface=listings`.** The shell mounts one
  surface at a time (`shell.setContent`), so the listing list is not in the
  document while Odalar is showing. The script loads the page twice rather than
  clicking a tab; the second load asserts the badge again, so both URLs are
  demo mode.

`?demo=1` is `import("./demo/fixtures")` — a lazy chunk. If that chunk is
missing from `priv/static/assets`, the badge and both lists come up empty and no
server log says why. Scenario b is what catches it, and the fourth ExUnit test
(`the demo fixtures chunk is served`) catches it without a browser.

### c) console — nothing reaches Chrome's log

Chrome is run with `--enable-logging=stderr --v=0`; page `console.error` and
uncaught exceptions arrive as `INFO:CONSOLE` lines. The script greps for
`CONSOLE|Uncaught|SEVERE` on all three URLs.

`--enable-logging` does **not** capture console output by default, and a check
that can never fire is worse than no check. So `run.sh` first loads a probe page
that logs and throws, and requires at least two hits before it trusts a clean
result from the app. If the probe comes back empty, the run reports
`the console detector caught nothing … a clean result below would be
meaningless` and fails. This was not theoretical: an early version of this check
grepped a log that silently contained nothing but a policy `INFO` line.

---

## 3. What the ExUnit file asserts

`test/e2e_test.exs`, four tests, `@tag :integration`:

1. **`/health` answers `{"status":"ok"}`** — the server is up, and it is zifiri
   (not merely something listening).
2. **`GET /` is 200, `text/html`**, body > 500 bytes, starts with `<!doctype
   html>`, contains `id="app"` and `/assets/index-`. The size check is there
   because a truncated or zeroed `priv/static/index.html` is served as a `200`
   with a body that is not HTML.
3. **`GET /api/pow` is bound** — `400`, body starts with `{"error":"refused"}`,
   body is exactly `16_384` bytes, `content-type: application/json`. A `404`
   here is a *different* answer: the router saying no route is bound. The test
   asserts `refute status == 404` with its own message before asserting `400`,
   so a missing route can never be read as a pass.
4. **the demo chunk is served** — `priv/static/assets/fixtures-*.js` resolves
   over HTTP with a non-empty body.

Requests go over `:gen_tcp`, not `:httpc`. On this toolchain `:inets` fails to
load `:http_util` (`function :http_util.timestamp/0 is undefined`), so `:httpc`
cannot make a request at all; `:gen_tcp` is in `:kernel` and has no such
problem. `Connection: close` means the body ends at EOF, and a chunked answer is
decoded rather than compared as if framing were content.

---

## 4. What this proves, and what it does not

**Proven**

- the built client bundle loads from the server in a real browser and boots;
- the shell's three tabs and the boot-skeleton replacement both happen;
- `?demo=1` renders fixture rooms and listings, not an empty state;
- no console error or uncaught exception on any of the three pages;
- `/`, `/health`, `/api/pow` and the static assets are served, and `/api/pow`
  answers with its constant refusal rather than a 404;
- the same facts, twice, by two independent paths (browser and HTTP).

**Not proven — say so rather than implying otherwise**

- **No interaction.** Nothing is typed, clicked or submitted. The composer, the
  POW solver, sending a message, closing a listing, the identity panel: all
  untouched. The browser never moves past first paint.
- **No WebSocket.** Presence and room fan-out over `Zifiri.Chat.Socket` are not
  exercised; there is no second client.
- **No API round trip in demo mode.** `?demo=1` short-circuits every fetch. It
  proves the *client* renders those shapes; it does not prove the API returns
  them.
- **Console, not `window.onerror`.** Only what Chrome logs is seen, and only for
  the load window (`--virtual-time-budget=8000`). A handler that throws later,
  on a timer past that budget, is invisible.
- **Chrome only, headless only.** No Firefox/Safari, no mobile viewport, no CSS
  layout assertion. `demo.png` is an artifact for a human, not an assertion.
- **The ExUnit side is not a browser.** It proves routing, static serving and
  the fixed-size refusal. Everything about rendering lives in `run.sh`.
- **Nothing about anonymity.** No claim in `docs/claims.md` is moved by this
  suite; it checks that the page loads, not who can be identified.

---

## 5. CI

`.github/workflows/ci.yml` already has the job: `e2e-gate` probes for
`scripts/e2e/run.sh`, and `e2e` runs it against a server the job starts itself
(`MIX_ENV=dev`, `mix phx.server`, `/health` polled for 60 s). It exports
`ZIFIRI_BASE_URL` and `CHROME_BIN`, and uploads `e2e/artifacts` — the DOM dumps,
the console logs and the screenshot — even when the job fails. `run.sh` reads
both variables and writes that directory when `GITHUB_ACTIONS=true`, so no
change to the workflow was needed to make the script fit.

The ExUnit file is not part of that job; it needs a live server and would only
re-assert what the browser run already covers. Run it locally, or add a step
after the server starts:

```yaml
      - name: e2e over http
        run: mix test --include integration test/e2e_test.exs
        env:
          ZIFIRI_E2E_BASE: ${{ env.ZIFIRI_BASE_URL }}
```

---

## 6. Traps found while building this

- **`priv/static/index.html` was 1294 NUL bytes.** The build output is
  gitignored and copied by `make static`; a zeroed copy is served as a `200`
  with `content-length: 1294`, and every `--dump-dom` check then fails in a way
  that looks like a JavaScript bug. `make static` fixes it. If the page is blank
  and the server says 200, look at the bytes first.
- **A foreign process on 4000 looks exactly like a working server** to `curl -f`
  and to any readiness check that only asks "does it answer". Ask `/health` for
  zifiri's exact body.
- **`:inets` is broken on this toolchain.** `:httpc` raises
  `:http_util.timestamp/0 is undefined` even though the beam file is on disk.
  Use `:gen_tcp`, or fix the OTP install before blaming the test.
- **One surface at a time.** Any DOM assertion about Mesajlar or İlanlar must
  load the page with `?surface=messages` / `?surface=listings`; the other
  surfaces' hosts are detached, so `--dump-dom` cannot see them.
